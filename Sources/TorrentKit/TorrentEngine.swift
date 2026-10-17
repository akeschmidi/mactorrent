import Foundation

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Fassade der Engine für die Oberfläche (MainActor, `ObservableObject`). Die eigentliche Arbeit macht der
/// Actor `EngineCore` abseits des Hauptthreads; hier landen nur gebündelte Zustandsmeldungen (4×/s).
@MainActor
public final class TorrentEngine: ObservableObject {
    public static let requestLength = 16 * 1024
    public static let maxConcurrentPerPeer = 16
    /// Öffentliche Tracker, zusätzlich zu denen in der Torrent-Datei. Private Torrents lassen sie aus.
    public static let publicTrackers = EngineCore.publicTrackers

    // MARK: Einstellungen (von der App gesetzt; wirken sofort)
    /// 0 = unbegrenzt bei den Limits (Bytes/s).
    public var maxPeers = 50 { didSet { pushSettings() } }
    public var downLimit: Int64 = 0 { didSet { pushSettings() } }
    public var upLimit: Int64 = 0 { didSet { pushSettings() } }
    /// Gemeinsame DHT der App; nil = aus. Private Torrents nutzen sie nie (BEP 27).
    public var dht: DHT? { didSet { pushSettings() } }
    /// Tests schalten das ab, damit kein öffentlicher Tracker angefragt wird.
    public var allowPublicTrackers = true { didSet { pushSettings() } }
    /// Gewünschter Listen-Port, 0 = zufällig aus 6881–6999. Gilt für alle Torrents gemeinsam.
    public var preferredPort = 0 { didSet { pushSettings() } }
    /// Endgültiger Ordner: ist er gesetzt und anders als `rootURL`, wandern die Dateien nach dem Download dorthin.
    public var completedDir: URL? { didSet { pushSettings() } }
    /// Wird nach dem Verschieben mit dem neuen Ordner aufgerufen (App speichert den Pfad).
    public var onRelocated: ((URL) -> Void)?

    // MARK: Zustand für die Oberfläche
    @Published public private(set) var state: EngineState = .idle
    @Published public private(set) var progress: TransferProgress
    @Published public var logs: [String] = []
    @Published public private(set) var peerList: [PeerInfo] = []
    @Published public private(set) var trackerList: [TrackerStatus] = []
    /// Je Datei (Reihenfolge von `torrent.entries`): wird heruntergeladen.
    @Published public private(set) var filesWanted: [Bool]

    public let torrent: TorrentInfo
    public private(set) var rootURL: URL
    /// Port, auf dem eingehende Peers ankommen (0 = Listener nicht aktiv).
    public private(set) var listenPort = 0
    public private(set) var isRunning = false

    private let store: PieceStore
    private let core: EngineCore
    private var tail: Task<Void, Never> = Task {}
    private var opsInFlight = 0
    private var coreRunning = false

    public init(torrent: TorrentInfo, rootURL: URL) {
        self.torrent = torrent
        self.rootURL = rootURL
        let store = PieceStore(torrent: torrent, rootURL: rootURL)
        self.store = store
        self.filesWanted = Array(repeating: true, count: torrent.entries.count)
        self.progress = TransferProgress(downloadedBytes: 0, downloadedPieces: 0,
                                         totalPieces: torrent.numberOfPieces, uploadedBytes: 0,
                                         peers: 0, isDone: false, wantedBytes: torrent.totalSize)
        let box = WeakBox<TorrentEngine>()
        self.core = EngineCore(torrent: torrent, rootURL: rootURL, store: store, settings: EngineSettings()) { update in
            // DispatchQueue.main ist strikt FIFO: Meldungen kommen in der Reihenfolge an, in der der Kern sie schickt.
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.apply(update) } }
        }
        box.value = self
    }

    deinit {
        let c = core
        Task { await c.stop() }
    }

    // MARK: - Steuerung

    public static func makePeerID() -> Data { EngineCore.makePeerID() }

    public func start() async {
        isRunning = true
        await enqueue { [core] in await core.start() }.value
    }

    /// Sofort wirksam für die UI (`isRunning`); der Kern räumt im Hintergrund auf und meldet dann `.paused` (fertig: `.done`).
    public func stop() {
        isRunning = false
        enqueue { [core] in await core.stop() }
    }

    public func recheck() async {
        await enqueue { [core] in await core.recheck() }.value
    }

    /// Gespeicherten Piece-Stand laden, damit ein Neustart nicht alles neu hasht.
    public func restoreBitfield(_ data: Data) {
        store.restore(bitfield: data)
        refreshProgress()
        if store.isComplete { state = .done }
    }

    /// Welche Dateien geladen werden (Index wie `torrent.entries`). Abgewählte Dateien werden nicht angefragt.
    public func setFilesWanted(_ wanted: [Bool]) {
        guard wanted.count == torrent.entries.count else { return }
        filesWanted = wanted
        store.setWanted(files: wanted)
        refreshProgress()
        enqueue { [core] in await core.filesChanged() }
    }

    /// Bitfield der geprüften Pieces für die Piece-Karte (thread-sicher, ohne Umweg über den Kern).
    public func pieceBitfield() -> Data { store.validBitfield() }

    public var isValid: Bool { store.isComplete }

    /// Fortschritt je Datei (0…1), aus dem Piece-Bitfield berechnet.
    public func fileProgress() -> [UUID: Double] {
        let bits = store.validBitfield()
        var out: [UUID: Double] = [:]
        for e in torrent.entries where !e.isDirectory {
            guard e.length > 0 else { out[e.id] = 1; continue }
            let first = e.pieceOffset / torrent.pieceLength
            let last = (e.pieceOffset + e.length - 1) / torrent.pieceLength
            var have = 0
            for i in first...last where bits[i / 8] & (1 << (7 - i % 8)) != 0 { have += 1 }
            out[e.id] = Double(have) / Double(last - first + 1)
        }
        return out
    }

    // MARK: - Intern

    private func pushSettings() {
        let s = EngineSettings(maxPeers: maxPeers, downLimit: downLimit, upLimit: upLimit, dht: dht,
                               allowPublicTrackers: allowPublicTrackers, preferredPort: preferredPort, completedDir: completedDir)
        enqueue { [core] in await core.configure(s) }
    }

    /// Aufträge laufen strikt nacheinander (stop → start darf sich nie überholen).
    @discardableResult
    private func enqueue(_ op: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        opsInFlight += 1
        let prev = tail
        let t = Task { @MainActor in
            await prev.value
            await op()
            await self.drainMain()
            self.opsInFlight -= 1
            if self.opsInFlight == 0 { self.isRunning = self.coreRunning }
        }
        tail = t
        return t
    }

    /// Wartet, bis alle bereits eingereihten Meldungen des Kerns angewendet sind.
    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    private func refreshProgress() {
        var p = progress
        p.downloadedPieces = store.wantedValidPieceCount
        p.totalPieces = store.wantedPieceCount
        p.verifiedBytes = store.wantedValidBytes
        p.wantedBytes = store.wantedBytes
        p.isDone = store.isComplete
        progress = p
    }

    fileprivate func apply(_ u: EngineUpdate) {
        if let s = u.state { state = s }
        if let p = u.progress { progress = p }
        if !u.logs.isEmpty {
            logs.append(contentsOf: u.logs)
            if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        }
        if let r = u.running {
            coreRunning = r
            if opsInFlight == 0 { isRunning = r }
        }
        if let l = u.listenPort { listenPort = l }
        if let r = u.rootURL { rootURL = r }
        if let m = u.relocated {
            rootURL = m
            completedDir = nil
            onRelocated?(m)
        }
        if let p = u.peers { peerList = p }
        if let t = u.trackers { trackerList = t }
    }
}
