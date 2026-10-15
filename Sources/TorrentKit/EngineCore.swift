import Foundation
import CryptoKit
import Network

/// Ein verbundener Peer, wie ihn die Oberfläche sieht.
public struct PeerInfo: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let address: String
    public let client: String
    public let incoming: Bool
    public var progress: Double
    public var downRate: Int64
    public var upRate: Int64
    /// Der Peer sperrt uns (wir dürfen nichts anfragen).
    public var theyChokeUs: Bool
    /// Wir geben dem Peer Upload frei.
    public var weUnchoke: Bool
    /// Der Peer will Daten von uns.
    public var interested: Bool
}

/// Zustand eines Trackers für die Anzeige.
public struct TrackerStatus: Identifiable, Sendable, Equatable {
    public var id: String { url }
    public let url: String
    public var status: String
    public var ok: Bool
    public var peers: Int
    public var lastAnnounce: Date?
}

/// Einstellungen, die die Fassade an den Kern weitergibt.
struct EngineSettings: Sendable {
    var maxPeers = 50
    var downLimit: Int64 = 0
    var upLimit: Int64 = 0
    var dht: DHT?
    var allowPublicTrackers = true
    var preferredPort = 0
    var completedDir: URL?
}

/// Alles, was der Kern der Oberfläche meldet. Felder sind optional: nur Geändertes wird gesetzt.
struct EngineUpdate: Sendable {
    var state: EngineState?
    var progress: TransferProgress?
    var logs: [String] = []
    var running: Bool?
    var listenPort: Int?
    var rootURL: URL?
    var relocated: URL?
    var peers: [PeerInfo]?
    var trackers: [TrackerStatus]?
}

private struct Block: Hashable {
    let piece: Int
    let offset: Int
}

/// Die eigentliche Engine: Tracker, Peers, Request-Scheduling, Piece-Prüfung, Upload.
/// Läuft als Actor abseits des Hauptthreads; `TorrentEngine` ist die dünne MainActor-Fassade für die Oberfläche.
actor EngineCore {
    /// Öffentliche Tracker, zusätzlich zu denen in der Torrent-Datei. Private Torrents lassen sie aus.
    nonisolated static let publicTrackers = [
        URL(string: "http://tracker.opentrackr.org:1337/announce")!,
        URL(string: "udp://tracker.opentrackr.org:1337/announce")!,
        URL(string: "udp://open.stealth.si:80/announce")!,
    ]
    static let requestLength = 16 * 1024
    static let maxConcurrentPerPeer = 16
    /// Tit-for-Tat: so viele Peers bekommen regulär Upload, dazu ein reihum wechselnder „optimistischer“.
    static let regularUnchokeSlots = 4
    /// Endgame: ab so wenigen fehlenden Pieces werden die letzten Blöcke mehrfach angefragt.
    static let endgamePieces = 24

    private final class Peer {
        let id = UUID()
        let addr: PeerAddress
        let conn: PeerConnection
        var client = "?"
        var validPieces: Data?
        var outstanding = 0
        var inflight = Set<Block>()
        var choked = true            // der Peer sperrt uns
        var incoming = false
        var unchoked = false         // wir geben dem Peer Upload frei
        var interested = false       // der Peer will von uns
        var sawPieces = false
        var loggedRequest = false
        var loggedBlock = false
        var gotData = false
        var downBytes: Int64 = 0, upBytes: Int64 = 0
        var windowDown: Int64 = 0, windowUp: Int64 = 0   // Rechoke-Fenster (10 s)
        var lastDown: Int64 = 0, lastUp: Int64 = 0       // für die Raten-Anzeige (1 s)
        var downRate: Int64 = 0, upRate: Int64 = 0
        let started = Date()
        init(addr: PeerAddress, conn: PeerConnection) { self.addr = addr; self.conn = conn }
        func has(_ p: Int) -> Bool {
            guard let b = validPieces, p >= 0, p < b.count * 8 else { return false }
            return b[p / 8] & (1 << (7 - p % 8)) != 0
        }
        func setHas(_ p: Int) {
            guard p >= 0 else { return }
            if validPieces == nil || validPieces!.count * 8 <= p {
                var b = validPieces ?? Data()
                while b.count * 8 <= p { b.append(0) }
                b[p / 8] |= (1 << (7 - p % 8))
                validPieces = b
            } else {
                validPieces![p / 8] |= (1 << (7 - p % 8))
            }
        }
        func progress(of total: Int) -> Double {
            guard let b = validPieces, total > 0 else { return 0 }
            return Double(b.reduce(0) { $0 + $1.nonzeroBitCount }) / Double(total)
        }
    }

    private struct Candidate {
        var lastTry = Date.distantPast
        var failures = 0
    }

    nonisolated let torrent: TorrentInfo
    nonisolated let store: PieceStore
    private nonisolated let sink: @Sendable (EngineUpdate) -> Void
    private var settings: EngineSettings
    private var rootURL: URL

    private var state: EngineState = .idle
    private var peerID: Data
    private var port: Int
    private var listenPort = 0
    private var relocating = false
    private var peers: [Peer] = []
    private var pool: [PeerAddress: Candidate] = [:]
    private var dhtSeen = Set<PeerAddress>()
    private var partial: [Int: [Int: Data]] = [:]
    /// Angefragte, noch nicht gelieferte Blöcke.
    private var openBlocks = Set<Block>()
    private var dupRequests: [Block: Int] = [:]
    private var downloadedBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var lastDownBytes: Int64 = 0
    private var lastUpBytes: Int64 = 0
    private var downSpeed: Int64 = 0
    private var upSpeed: Int64 = 0
    private var availability: [Int]
    private var downBudget: Int64 = 0
    private var upBudget: Int64 = 0
    private var uploadQueue: [(peer: Peer, piece: Int, offset: Int, length: Int)] = []
    private var writing = Set<Int>()
    private var running = false
    private var startedAnnounced = false
    private var completedAnnounced = false
    private var allTasks: [Task<Void, Never>] = []
    private var optimisticID: UUID?
    private var rechokeRound = 0
    private var trackerStates: [String: TrackerStatus] = [:]

    private var pendingLogs: [String] = []
    private var lastFlush = Date.distantPast

    init(torrent: TorrentInfo, rootURL: URL, store: PieceStore, settings: EngineSettings,
         sink: @escaping @Sendable (EngineUpdate) -> Void) {
        self.torrent = torrent
        self.rootURL = rootURL
        self.store = store
        self.settings = settings
        self.sink = sink
        self.peerID = Self.makePeerID()
        self.port = Int.random(in: 6881...6999)
        self.availability = Array(repeating: 0, count: torrent.numberOfPieces)
    }

    func configure(_ s: EngineSettings) { settings = s }

    private var isComplete: Bool { store.isComplete }

    // MARK: - Meldungen an die Oberfläche

    private func log(_ s: String) {
        pendingLogs.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(s)")
        if pendingLogs.count > 300 { pendingLogs.removeFirst(pendingLogs.count - 300) }
    }

    private func setState(_ s: EngineState) {
        state = s
        flush(force: true)
    }

    private func buildProgress() -> TransferProgress {
        TransferProgress(
            downloadedBytes: downloadedBytes,
            downloadedPieces: store.wantedValidPieceCount,
            totalPieces: store.wantedPieceCount,
            uploadedBytes: uploadedBytes,
            peers: peers.count,
            isDone: store.isComplete,
            downSpeed: downSpeed,
            upSpeed: upSpeed,
            verifiedBytes: store.wantedValidBytes,
            dhtPeers: dhtSeen.count,
            wantedBytes: store.wantedBytes
        )
    }

    private func peerInfos() -> [PeerInfo] {
        peers.map {
            PeerInfo(id: $0.id, address: $0.addr.label, client: $0.client, incoming: $0.incoming,
                     progress: $0.progress(of: torrent.numberOfPieces), downRate: $0.downRate, upRate: $0.upRate,
                     theyChokeUs: $0.choked, weUnchoke: $0.unchoked, interested: $0.interested)
        }.sorted { ($0.downRate + $0.upRate) > ($1.downRate + $1.upRate) }
    }

    /// Schickt den aktuellen Stand an die Oberfläche. Ohne `force` höchstens 4× pro Sekunde.
    private func flush(force: Bool = false, withPeers: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFlush) >= 0.2 else { return }
        lastFlush = now
        var u = EngineUpdate()
        u.state = state
        u.progress = buildProgress()
        u.logs = pendingLogs
        pendingLogs = []
        u.running = running
        u.listenPort = listenPort
        u.rootURL = rootURL
        if withPeers || force {
            u.peers = peerInfos()
            u.trackers = torrent.trackerURLs.map { trackerStates[$0.absoluteString] ?? TrackerStatus(url: $0.absoluteString, status: "–", ok: false, peers: 0, lastAnnounce: nil) }
                + trackerStates.values.filter { s in !torrent.trackerURLs.contains { $0.absoluteString == s.url } }
        }
        sink(u)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !running else { return }
        // VPN-Schutz: ohne die erzwungene Schnittstelle startet nichts (Kill-Switch).
        guard !NetworkPolicy.shared.isBlocked else {
            setState(.failed(String(localized: "VPN-Schutz: Schnittstelle nicht verbunden", bundle: .main)))
            return
        }
        running = true
        peerID = Self.makePeerID() // Anonymer Modus wirkt ab dem nächsten Start
        setState(.scanning)
        log(String(localized: "Scan: vorhandene Pieces werden geprüft…", bundle: .main))
        if (try? store.prepareFiles()) == nil {
            log(String(localized: "Dateien konnten nicht angelegt werden", bundle: .main))
            running = false
            setState(.failed(String(localized: "Dateianlage fehlgeschlagen", bundle: .main)))
            return
        }
        await scan()
        guard running else { return }
        let valid = store.validatedCount
        log(String(localized: "Scan: \(valid)/\(torrent.numberOfPieces) Pieces gültig.", bundle: .main))
        log(String(localized: "Info-Hash \(torrent.infoHashHex) · Peer-ID \(String(decoding: peerID.prefix(8), as: UTF8.self)) · Port \(port)", bundle: .main))
        if torrent.trackerURLs.isEmpty {
            log(String(localized: "Keine Tracker-URL in der Torrent-Datei", bundle: .main))
        } else {
            for url in torrent.trackerURLs { log(String(localized: "Tracker-URL \(url.absoluteString)", bundle: .main)) }
        }
        // Fertige Torrents laufen weiter als Seeder: Listener + Tracker, keine eigenen Verbindungen.
        state = isComplete ? .done : .downloading
        relocateIfNeeded()
        // Anonymer Modus: keine eingehenden Verbindungen, damit uns niemand über einen offenen Port findet.
        if !NetworkPolicy.shared.anonymous { await listen() }
        guard running else { return }
        allTasks = [
            Task { await self.connectLoop() },
            Task { await self.trackerLoop() },
            Task { await self.requestLoop() },
            Task { await self.probeLoop() },
        ]
        if settings.dht != nil && !torrent.isPrivate { allTasks.append(Task { await self.dhtLoop() }) }
        flush(force: true)
    }

    func stop() {
        running = false
        for t in allTasks { t.cancel() }
        allTasks = []
        PeerListener.shared.unregister(infoHash: torrent.infoHash)
        listenPort = 0
        for p in peers {
            if !completedAnnounced { Task { await self.announceFor(event: "stopped") } }
            p.conn.close()
            break // ein „stopped“ pro Torrent genügt
        }
        for p in peers { p.conn.close() }
        peers = []
        partial = [:]
        for k in pool.keys { pool[k]?.lastTry = .distantPast }
        openBlocks = []
        dupRequests = [:]
        uploadQueue = []
        availability = Array(repeating: 0, count: torrent.numberOfPieces)
        downSpeed = 0; upSpeed = 0
        optimisticID = nil
        setState(.paused)
    }

    func recheck() async {
        log(String(localized: "Re-Check: alle Pieces werden neu validiert…", bundle: .main))
        // Läuft der Download, bleibt der bekannte Stand; sonst wird komplett neu geprüft.
        let full = !running
        if full {
            for i in 0..<torrent.numberOfPieces { store.setValid(i, false) }
            setState(.scanning)
        }
        await scan()
        log(String(localized: "Re-Check: \(store.validatedCount)/\(torrent.numberOfPieces) gültig.", bundle: .main))
        if full { state = store.isComplete ? .done : .paused }
        flush(force: true)
    }

    /// Dateiauswahl hat sich geändert: Zähler neu, Zustand anpassen.
    func filesChanged() {
        if running {
            if store.isComplete, state == .downloading {
                state = .done
                Task { await self.announce(event: "completed") }
                relocateIfNeeded()
            } else if !store.isComplete, state == .done {
                state = .downloading
                completedAnnounced = false
            }
        }
        flush(force: true)
    }

    /// SHA-1-Prüfung der noch offenen Pieces, abseits des Actors.
    private func scan() async {
        let store = self.store
        await Task.detached(priority: .utility) { [weak self] in
            var n = 0
            for i in store.pendingPieceList() {
                if store.validatePiece(i) { store.setValid(i, true) }
                n += 1
                if n % 32 == 0 { await self?.flush(force: true) }
            }
        }.value
    }

    /// Verschiebt fertige Dateien aus dem Unfertig-Ordner in den Zielordner.
    private func relocateIfNeeded() {
        guard isComplete, !relocating, let dest = settings.completedDir, dest != rootURL else { return }
        relocating = true
        let src = rootURL
        Task {
            let moved: URL? = await Task.detached {
                let fm = FileManager.default
                var target = dest
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = dest.deletingLastPathComponent().appendingPathComponent("\(dest.lastPathComponent) \(n)")
                    n += 1
                }
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: target)
                    return target
                } catch { return nil }
            }.value
            if let moved {
                store.relocate(to: moved)
                rootURL = moved
                settings.completedDir = nil
                log(String(localized: "Verschoben nach \(moved.path)", bundle: .main))
                var u = EngineUpdate()
                u.relocated = moved
                sink(u)
            } else {
                log(String(localized: "Verschieben nach \(dest.path) fehlgeschlagen – Dateien bleiben in \(src.path)", bundle: .main))
            }
            relocating = false
            flush(force: true)
        }
    }

    // MARK: - DHT

    /// Sucht Peers im DHT: bei Peer-Mangel alle 30 s, sonst alle 5 min. Meldet uns dabei mit unserem Listener-Port an.
    private func dhtLoop() async {
        while running {
            guard let dht = settings.dht else { return }
            log(String(localized: "DHT: Suche (\(dht.nodeCount) Knoten)", bundle: .main))
            let announce = (listenPort == 0 || NetworkPolicy.shared.anonymous) ? nil : listenPort
            await dht.lookup(infoHash: torrent.infoHash, announcePort: announce) { [weak self] found in
                Task { await self?.addDHTPeers(found) }
            }
            var wait = 300
            while running && wait > 0 {
                try? await Task.sleep(for: .seconds(5))
                wait -= 5
                if peers.isEmpty && !isComplete && wait > 30 { wait = 30 }
            }
        }
    }

    private func addDHTPeers(_ found: [PeerAddress]) {
        let fresh = found.filter { dhtSeen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        log(String(localized: "DHT: \(fresh.count) neue Peers (\(dhtSeen.count) gesamt)", bundle: .main))
        addCandidates(fresh)
    }

    // MARK: - Kandidaten-Pool

    /// Alle bekannten Adressen (Tracker, DHT) wandern in den Pool. Der `connectLoop` füllt daraus die freien Plätze auf
    /// und versucht Fehlschläge mit wachsendem Abstand erneut.
    private func addCandidates(_ addrs: [PeerAddress]) {
        for a in addrs where pool[a] == nil && pool.count < 3000 { pool[a] = Candidate() }
    }

    private func connectLoop() async {
        while running {
            if !isComplete && peers.count < settings.maxPeers {
                let now = Date()
                let due = pool
                    .filter { !peerExists($0.key) && now.timeIntervalSince($0.value.lastTry) >= min(900, 30 * pow(2, Double($0.value.failures))) }
                    .sorted { $0.value.failures < $1.value.failures }
                    .prefix(min(settings.maxPeers - peers.count, 10))
                for (addr, _) in due {
                    pool[addr]?.lastTry = now
                    Task { await self.connect(addr) }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Tracker

    private func trackerLoop() async {
        while running {
            var ok = false
            var gotPeers = false
            var interval: TimeInterval = 300
            var urls = torrent.trackerURLs
            if settings.allowPublicTrackers && !NetworkPolicy.shared.anonymous && !torrent.isPrivate {
                for extra in Self.publicTrackers where !urls.contains(extra) { urls.append(extra) }
            }
            let event: String? = completedAnnounced ? nil : (startedAnnounced ? nil : "started")
            for url in urls {
                let key = url.absoluteString
                let scheme = url.scheme?.lowercased()
                guard scheme == "http" || scheme == "https" || scheme == "udp" else {
                    trackerStates[key] = TrackerStatus(url: key, status: String(localized: "Schema \(scheme ?? "?") nicht unterstützt", bundle: .main), ok: false, peers: 0, lastAnnounce: nil)
                    log(String(localized: "Tracker \(key): Schema \(scheme ?? "?") nicht unterstützt", bundle: .main))
                    continue
                }
                let left = max(0, store.wantedBytes - store.wantedValidBytes)
                log(String(localized: "Announce \(url.host ?? key) event=\(event ?? "-") left=\(left)", bundle: .main))
                do {
                    let res = try await TrackerClient.announce(
                        url: url, infoHash: torrent.infoHash, peerID: peerID, port: port,
                        uploaded: uploadedBytes, downloaded: downloadedBytes, left: left, event: event)
                    if let failure = res.failureReason {
                        trackerStates[key] = TrackerStatus(url: key, status: failure, ok: false, peers: 0, lastAnnounce: Date())
                        log(String(localized: "Tracker \(url.host ?? ""): \(failure)", bundle: .main))
                        continue
                    }
                    log(String(localized: "Tracker \(url.host ?? ""): \(res.peers.count) Peers, Intervall \(Int(res.interval))s", bundle: .main))
                    trackerStates[key] = TrackerStatus(url: key, status: String(localized: "Aktiv · Intervall \(Int(res.interval)) s", bundle: .main), ok: true, peers: res.peers.count, lastAnnounce: Date())
                    addCandidates(res.peers)
                    ok = true
                    if !res.peers.isEmpty { gotPeers = true }
                    interval = min(interval, max(15, res.interval))
                } catch {
                    trackerStates[key] = TrackerStatus(url: key, status: error.localizedDescription, ok: false, peers: 0, lastAnnounce: Date())
                    log(String(localized: "Tracker \(url.host ?? ""): \(error.localizedDescription)", bundle: .main))
                }
            }
            if event == "started" { startedAnnounced = true }
            if !ok { interval = 60 }
            // Stirbt der einzige Peer sofort (alter Port, VPN-Reset), nicht die ganze Intervallzeit warten.
            var left = interval
            var hurried = false
            while running && left > 0 {
                try? await Task.sleep(for: .seconds(min(5, left)))
                left -= 5
                if gotPeers && peers.isEmpty && !isComplete && left > 10 {
                    if !hurried {
                        log(String(localized: "Keine verbundenen Peers, nächster Announce in 10s", bundle: .main))
                        hurried = true
                    }
                    left = 10
                }
            }
        }
    }

    private func announce(event: String) async {
        for url in torrent.trackerURLs {
            _ = try? await TrackerClient.announce(url: url, infoHash: torrent.infoHash,
                peerID: peerID, port: port, uploaded: uploadedBytes,
                downloaded: downloadedBytes, left: max(0, store.wantedBytes - store.wantedValidBytes), event: event)
        }
        completedAnnounced = (event == "completed")
    }

    private func announceFor(event: String) async {
        for url in torrent.trackerURLs {
            _ = try? await TrackerClient.announce(url: url, infoHash: torrent.infoHash,
                peerID: peerID, port: port, uploaded: uploadedBytes,
                downloaded: downloadedBytes, left: max(0, store.wantedBytes - store.wantedValidBytes), event: event)
        }
    }

    // MARK: - Peers

    private func peerExists(_ addr: PeerAddress) -> Bool {
        peers.contains { $0.addr == addr }
    }

    private func connect(_ addr: PeerAddress) async {
        guard running, !isComplete, peers.count < settings.maxPeers, !peerExists(addr) else { return }
        let conn = PeerConnection(infoHash: torrent.infoHash, peerID: peerID)
        let events = conn.makeStream()
        conn.start(host: addr.ip, port: addr.port)
        let peer = Peer(addr: addr, conn: conn)
        peers.append(peer)
        log(String(localized: "Peer \(addr.label): verbinde…", bundle: .main))
        await peerLoop(peer: peer, events: events)
    }

    // MARK: Eingehende Verbindungen

    /// Meldet den Torrent am gemeinsamen Listener an (ein Port für alle Torrents).
    private func listen() async {
        let wanted = settings.preferredPort
        let p = await PeerListener.shared.register(infoHash: torrent.infoHash, preferred: wanted) { [weak self] nw, pre in
            Task { await self?.accept(nw, preread: pre) }
        }
        if p > 0 {
            port = p
            listenPort = p
            log(String(localized: "Listener auf Port \(p)", bundle: .main))
        } else if wanted > 0 {
            port = wanted
            log(String(localized: "Port \(wanted) ist belegt – keine eingehenden Verbindungen", bundle: .main))
        } else {
            log(String(localized: "Kein freier Port – nur ausgehende Verbindungen", bundle: .main))
        }
    }

    private func accept(_ nw: NWConnection, preread: Data) async {
        guard running, peers.count < settings.maxPeers else { nw.cancel(); return }
        var host = "?"
        var rport = 0
        if case let .hostPort(h, pt) = nw.endpoint {
            host = "\(h)".split(separator: "%").first.map(String.init) ?? "?"
            rport = Int(pt.rawValue)
        }
        let conn = PeerConnection(infoHash: torrent.infoHash, peerID: peerID, accepted: nw)
        let events = conn.makeStream()
        conn.startAccepted(preread: preread)
        let peer = Peer(addr: PeerAddress(ip: host, port: rport), conn: conn)
        peer.incoming = true
        peers.append(peer)
        log(String(localized: "Peer \(peer.addr.label): eingehend", bundle: .main))
        await peerLoop(peer: peer, events: events)
    }

    /// „-qB4650-“ → „qBittorrent 4.6.5“ usw. (Azureus-Stil); sonst „?“.
    private static func clientName(_ id: String) -> String {
        let c = Array(id.utf8)
        guard c.count >= 8, c[0] == 45, c[7] == 45 else { return "?" }
        let code = String(decoding: c[1...2], as: UTF8.self)
        let names = ["qB": "qBittorrent", "TR": "Transmission", "UT": "µTorrent", "lt": "libtorrent", "LT": "libtorrent",
                     "DE": "Deluge", "AZ": "Azureus", "BT": "BitTorrent", "MT": "MacTorrent", "WW": "WebTorrent",
                     "UM": "µTorrent Mac", "KT": "KTorrent", "FD": "Free Download Manager", "BI": "BiglyBT"]
        let digits = String(decoding: c[3...6], as: UTF8.self)
        return "\(names[code] ?? code) \(digits)"
    }

    private func peerLoop(peer: Peer, events: AsyncThrowingStream<PeerEvent, Error>) async {
        defer {
            if peers.contains(where: { $0.id == peer.id }) {
                log(String(localized: "Peer \(peer.addr.label): getrennt.", bundle: .main))
                disconnect(peer)
            }
        }
        do {
            for try await event in events {
                switch event {
                case .handshake(let peerIdStr):
                    peer.client = Self.clientName(peerIdStr)
                    log(String(localized: "Peer \(peer.addr.label): Handshake OK (\(peer.client))", bundle: .main))
                    // Bitfield muss die erste Nachricht sein, sonst trennt der Peer.
                    let bits = store.validBitfield()
                    if bits.contains(where: { $0 != 0 }) { send(peer, PeerConnection.frame(5, bits)) }
                    if !isComplete { send(peer, PeerConnection.frame(2)) }
                case .message(let data):
                    handle(peer, data)
                }
            }
        } catch {
            log(String(localized: "Peer \(peer.addr.label): \(error.localizedDescription)", bundle: .main))
        }
    }

    private func disconnect(_ peer: Peer) {
        // Pool-Buchführung: wer Daten geliefert hat, bleibt „gut“; wer nur kam und ging, wird seltener probiert.
        if !peer.incoming, let c = pool[peer.addr] {
            pool[peer.addr]?.failures = peer.gotData ? 0 : c.failures + 1
        }
        release(peer)
        countAvailability(peer, -1)
        peers.removeAll { $0.id == peer.id }
        if optimisticID == peer.id { optimisticID = nil }
    }

    private func countAvailability(_ peer: Peer, _ delta: Int) {
        for i in 0..<availability.count where peer.has(i) { availability[i] += delta }
    }

    /// Choke oder Trennung: die Blöcke darf ein anderer Peer holen.
    private func release(_ peer: Peer) {
        openBlocks.subtract(peer.inflight)
        peer.inflight.removeAll()
        peer.outstanding = 0
    }

    private func handle(_ peer: Peer, _ data: Data) {
        switch PeerMessage.parse(data) {
        case .keepAlive, .unknown, .cancel, .pong, .extensionMessage:
            break
        case .choke:
            peer.choked = true
            release(peer)
        case .unchoke:
            peer.choked = false
            pump(peer)
        case .interested:
            peer.interested = true
            // Freier Platz: sofort entsperren; sonst entscheidet der nächste Rechoke (alle 10 s).
            if !peer.unchoked, peers.filter(\.unchoked).count < Self.regularUnchokeSlots + 1 {
                peer.unchoked = true
                send(peer, PeerConnection.frame(1))
            }
        case .notInterested:
            peer.interested = false
            if peer.unchoked {
                peer.unchoked = false
                send(peer, PeerConnection.frame(0))
            }
        case .have(let p):
            guard p >= 0, p < availability.count else { return } // ungültiger Index: ignorieren statt Bitfeld aufzublasen
            if !peer.has(p) { availability[p] += 1 }
            peer.setHas(p)
            peer.sawPieces = true
        case .bitfield(let b):
            countAvailability(peer, -1)
            peer.validPieces = b
            countAvailability(peer, 1)
            if b.contains(where: { $0 != 0 }) { peer.sawPieces = true }
        case .piece(let p, let o, let d):
            assemble(peer: peer, piece: p, offset: o, data: d)
        case .request(let p, let o, let l):
            upload(peer: peer, piece: p, offset: o, length: l)
        case .ping:
            send(peer, PeerConnection.frame(0x11)) // pong
        }
    }

    private func send(_ peer: Peer, _ frame: Data) {
        do { try peer.conn.send(frame) }
        catch { log(String(localized: "Sendfehler (\(peer.addr.label)): \(error.localizedDescription)", bundle: .main)) }
    }

    // MARK: - Tit-for-Tat

    /// Alle 10 s: die 4 Peers, die uns (beim Laden) am meisten liefern bzw. (beim Seeden) am schnellsten
    /// nehmen, bekommen Upload; dazu ein optimistischer, der alle 30 s wechselt. Alle anderen werden gesperrt.
    private func rechoke() {
        rechokeRound += 1
        let seeding = isComplete
        func score(_ p: Peer) -> Int64 { seeding ? p.windowUp : p.windowDown }
        let interested = peers.filter(\.interested)
        var keep = Set(interested.sorted { score($0) > score($1) }.prefix(Self.regularUnchokeSlots).map(\.id))
        let optimisticStillValid = optimisticID.map { id in interested.contains { $0.id == id } } ?? false
        if rechokeRound % 3 == 1 || !optimisticStillValid {
            optimisticID = interested.filter { !keep.contains($0.id) }.randomElement()?.id
        }
        if let o = optimisticID { keep.insert(o) }
        for p in peers {
            let want = keep.contains(p.id)
            if want && !p.unchoked {
                p.unchoked = true
                send(p, PeerConnection.frame(1))
            } else if !want && p.unchoked {
                p.unchoked = false
                send(p, PeerConnection.frame(0))
            }
            p.windowDown = 0; p.windowUp = 0
        }
    }

    // MARK: - Download

    /// Partials zusammenfügen → Hash + Schreiben abseits des Actors → Bitset.
    private func assemble(peer: Peer, piece: Int, offset: Int, data: Data) {
        let block = Block(piece: piece, offset: offset)
        if peer.inflight.remove(block) != nil { peer.outstanding = max(0, peer.outstanding - 1) }
        openBlocks.remove(block)
        dupRequests[block] = nil

        guard (0..<torrent.numberOfPieces).contains(piece) else { return }
        let pLen = store.pieceLength(piece)
        guard pLen > 0, offset >= 0, data.count > 0, offset + data.count <= pLen else {
            log(String(localized: "Peer \(peer.addr.label): Block verworfen piece \(piece) offset \(offset) len \(data.count)", bundle: .main))
            return
        }
        // Endgame-Duplikate nach Abschluss des Pieces ignorieren (sonst entsteht ein verwaister Partial-Eintrag).
        if store.isPieceValid(piece) || writing.contains(piece) { pump(peer); return }
        let fresh = partial[piece]?[offset] == nil
        partial[piece, default: [:]][offset] = data
        peer.gotData = true
        if fresh {
            downloadedBytes += Int64(data.count)
            peer.downBytes += Int64(data.count)
            peer.windowDown += Int64(data.count)
            cancelDuplicates(of: block, except: peer)
            if !peer.loggedBlock {
                peer.loggedBlock = true
                log(String(localized: "Peer \(peer.addr.label): erster Block (Piece \(piece))", bundle: .main))
            }
        }

        guard let full = reconstruct(piece: piece) else {
            pump(peer)
            return
        }
        guard writing.insert(piece).inserted else { return }
        let store = self.store
        let expected = torrent.pieceHashes[piece]
        Task {
            // SHA-1 im Speicher + Schreiben, beides abseits des Actors.
            let result: Int = await Task.detached {
                guard Data(Insecure.SHA1.hash(data: full)) == expected else { return 1 }
                return store.writePieceBytes(full, index: piece) ? 0 : 2
            }.value
            self.finishWrite(piece: piece, result: result, peer: peer)
        }
    }

    private func finishWrite(piece: Int, result: Int, peer: Peer) {
        writing.remove(piece)
        guard running else { return }
        guard result == 0 else {
            log(result == 1 ? "Piece \(piece): Hash ungültig, verworfen." : "Schreibfehler Piece \(piece)")
            discardPiece(piece)
            return
        }
        partial[piece] = nil
        openBlocks = Set(openBlocks.filter { $0.piece != piece })
        store.setValid(piece, true)
        broadcastHave(piece)
        pump(peer)
        if store.isComplete, state != .done {
            log(String(localized: "Download fertig.", bundle: .main))
            state = .done
            flush(force: true)
            Task { await self.announce(event: "completed") }
            relocateIfNeeded()
        }
    }

    private func discardPiece(_ piece: Int) {
        if let chunks = partial[piece] {
            let n = chunks.values.reduce(0) { $0 + $1.count }
            downloadedBytes = max(0, downloadedBytes - Int64(n))
        }
        partial[piece] = nil
        openBlocks = Set(openBlocks.filter { $0.piece != piece })
        for peer in peers {
            let dropped = peer.inflight.filter { $0.piece == piece }
            if dropped.isEmpty { continue }
            peer.inflight.subtract(dropped)
            peer.outstanding = max(0, peer.outstanding - dropped.count)
        }
    }

    private func reconstruct(piece: Int) -> Data? {
        guard let chunks = partial[piece] else { return nil }
        var full = Data()
        var off = 0
        let pLen = store.pieceLength(piece)
        while off < pLen {
            let l = min(Self.requestLength, pLen - off)
            guard let c = chunks[off], c.count == l else { return nil }
            full.append(c)
            off += l
        }
        return full
    }

    private func broadcastHave(_ piece: Int) {
        let frame = PeerConnection.frame(4, Data([
            UInt8((piece >> 24) & 0xFF), UInt8((piece >> 16) & 0xFF),
            UInt8((piece >> 8) & 0xFF), UInt8(piece & 0xFF)
        ]))
        for peer in peers { send(peer, frame) }
    }

    /// Endgame: ein doppelt angefragter Block ist eingetroffen → bei den anderen Peers per `cancel` zurückziehen.
    private func cancelDuplicates(of block: Block, except sender: Peer) {
        for p in peers where p.id != sender.id && p.inflight.remove(block) != nil {
            p.outstanding = max(0, p.outstanding - 1)
            var payload = Data()
            appendBE32(&payload, block.piece); appendBE32(&payload, block.offset)
            appendBE32(&payload, min(Self.requestLength, store.pieceLength(block.piece) - block.offset))
            send(p, PeerConnection.frame(8, payload))
        }
    }

    // MARK: - Requests

    private func requestLoop() async {
        while running {
            try? await Task.sleep(nanoseconds: 250_000_000)
            // Token-Bucket: pro Tick ein Viertel des Limits, maximal eine Sekunde Vorrat.
            downBudget = min(settings.downLimit, downBudget + settings.downLimit / 4)
            upBudget = min(settings.upLimit, upBudget + settings.upLimit / 4)
            drainUploads()
            for peer in peers {
                if !peer.incoming && !isComplete && !peer.sawPieces && Date().timeIntervalSince(peer.started) > 8 {
                    log(String(localized: "Peer \(peer.addr.label): keine Pieces gemeldet, trenne", bundle: .main))
                    peer.sawPieces = true
                    peer.conn.close()
                    continue
                }
                pump(peer)
            }
            flush()
        }
    }

    /// Füllt die Pipeline mit verschiedenen 16-KiB-Blöcken.
    private func pump(_ peer: Peer) {
        guard !peer.choked, !isComplete else { return }
        while peer.outstanding < Self.maxConcurrentPerPeer {
            if settings.downLimit > 0 && downBudget <= 0 { break }
            guard let block = nextBlock(peer: peer) else { break }
            let len = min(Self.requestLength, store.pieceLength(block.piece) - block.offset)
            guard len > 0 else { break }
            downBudget -= Int64(len)
            var payload = Data()
            appendBE32(&payload, block.piece)
            appendBE32(&payload, block.offset)
            appendBE32(&payload, len)
            send(peer, PeerConnection.frame(6, payload))
            openBlocks.insert(block)
            peer.inflight.insert(block)
            peer.outstanding += 1
        }
    }

    /// Laufendes Piece zuerst, sonst das seltenste gewünschte (zufällig bei Gleichstand); am Ende Endgame-Duplikate.
    private func nextBlock(peer: Peer) -> Block? {
        for piece in partial.keys where peer.has(piece) {
            if let offset = nextOffset(piece: piece) { return Block(piece: piece, offset: offset) }
        }
        let have = store.validBitfield()
        var best: [Int] = []
        var bestCount = Int.max
        var missing = 0
        for i in 0..<torrent.numberOfPieces where have[i / 8] & (1 << (7 - i % 8)) == 0 && store.isWanted(i) {
            missing += 1
            guard partial[i] == nil, peer.has(i) else { continue }
            let c = availability[i]
            if c < bestCount { bestCount = c; best = [i] }
            else if c == bestCount { best.append(i) }
        }
        for piece in best.shuffled() {
            if let offset = nextOffset(piece: piece) { return Block(piece: piece, offset: offset) }
        }
        // Endgame: nichts Neues mehr zu holen, aber noch Pieces offen → bereits angefragte Blöcke bei einem
        // zweiten Peer anfragen, damit ein langsamer Peer die letzten Prozent nicht aufhält.
        if missing > 0, missing <= Self.endgamePieces {
            for block in openBlocks.shuffled()
            where peer.has(block.piece) && !peer.inflight.contains(block)
                && partial[block.piece]?[block.offset] == nil && (dupRequests[block] ?? 0) < 2 {
                dupRequests[block, default: 0] += 1
                return block
            }
        }
        return nil
    }

    private func nextOffset(piece: Int) -> Int? {
        let pLen = store.pieceLength(piece)
        var off = 0
        while off < pLen {
            if partial[piece]?[off] == nil && !openBlocks.contains(Block(piece: piece, offset: off)) { return off }
            let step = min(Self.requestLength, pLen - off)
            if step <= 0 { break }
            off += step
        }
        return nil
    }

    // MARK: - Upload

    private func upload(peer: Peer, piece: Int, offset: Int, length: Int) {
        guard peer.unchoked else { return } // gesperrte Peers dürfen nichts anfragen (BEP 3)
        if settings.upLimit > 0 {
            if uploadQueue.count < 256 { uploadQueue.append((peer, piece, offset, length)) }
            return
        }
        serve(peer: peer, piece: piece, offset: offset, length: length)
    }

    private func drainUploads() {
        while settings.upLimit > 0, upBudget > 0, !uploadQueue.isEmpty {
            let r = uploadQueue.removeFirst()
            guard peers.contains(where: { $0.id == r.peer.id }) else { continue }
            upBudget -= Int64(r.length)
            serve(peer: r.peer, piece: r.piece, offset: r.offset, length: r.length)
        }
    }

    private func serve(peer: Peer, piece: Int, offset: Int, length: Int) {
        if relocating { return } // Dateien sind gerade unterwegs; der Peer fragt erneut
        guard (0..<torrent.numberOfPieces).contains(piece) else { send(peer, PeerConnection.frame(0)); return }
        let pLen = store.pieceLength(piece)
        guard length > 0, offset >= 0, offset + length <= pLen else { send(peer, PeerConnection.frame(0)); return }
        guard store.isPieceValid(piece) else { send(peer, PeerConnection.frame(0)); return }
        let start = piece * torrent.pieceLength + offset
        guard let data = store.readSlice(offset: start, length: length) else { send(peer, PeerConnection.frame(0)); return }
        var payload = Data()
        appendBE32(&payload, piece); appendBE32(&payload, offset)
        payload.append(data)
        send(peer, PeerConnection.frame(7, payload))
        uploadedBytes += Int64(length)
        peer.upBytes += Int64(length)
        peer.windowUp += Int64(length)
    }

    // MARK: - Keepalive, Raten, Rechoke

    private func probeLoop() async {
        var tick = 0
        while running {
            try? await Task.sleep(for: .seconds(1))
            // stop() bricht den Sleep ab; ohne diese Prüfung überschreibt ein letzter Durchlauf die auf 0 gesetzte Rate.
            guard running else { return }
            tick += 1
            if tick % 5 == 0 { for peer in peers { send(peer, Data()) } } // Keep-alive, Länge 0
            if tick % 10 == 0 { rechoke() }
            // Geglättet (EMA), sonst springt die Anzeige im Sekundentakt.
            let d = max(0, downloadedBytes - lastDownBytes), u = max(0, uploadedBytes - lastUpBytes)
            downSpeed = downSpeed == 0 ? d : (downSpeed * 7 + d * 3) / 10
            upSpeed = upSpeed == 0 ? u : (upSpeed * 7 + u * 3) / 10
            lastDownBytes = downloadedBytes
            lastUpBytes = uploadedBytes
            for p in peers {
                p.downRate = p.downBytes - p.lastDown; p.upRate = p.upBytes - p.lastUp
                p.lastDown = p.downBytes; p.lastUp = p.upBytes
            }
            flush(force: true, withPeers: true)
        }
    }

    // MARK: - PeerID

    /// Anonymer Modus: komplett zufällig, ohne Client-Kürzel. Sonst Azureus-Stil `-MT0001-` + Zufall.
    nonisolated static func makePeerID() -> Data {
        var id = NetworkPolicy.shared.anonymous ? Data() : Data("-MT0001-".utf8)
        while id.count < 20 { id.append(UInt8.random(in: 0...255)) }
        return id
    }
}

@inline(__always)
func appendBE32(_ data: inout Data, _ value: Int) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}
