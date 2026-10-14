import Foundation
import CryptoKit

/// Kern-Engine: Tracker-Announces, Peer-Verbindungen, Request-Scheduling,
/// Piece-Assembly + Validierung, Upload. Läuft komplett auf dem MainActor
/// (SwiftUI-@Published, lock-frei).
@MainActor
public final class TorrentEngine: ObservableObject {
    public static let requestLength = 16 * 1024
    public static let maxConcurrentPerPeer = 4
    public static let maxPeers = 24

    @Published public private(set) var state: EngineState = .idle
    @Published public private(set) var progress: TransferProgress
    @Published public var logs: [String] = []

    public let torrent: TorrentInfo
    public let rootURL: URL
    private let store: PieceStore
    private let peerID: Data
    private let port: Int

    private final class Peer {
        let id = UUID()
        let addr: PeerAddress
        let conn: PeerConnection
        var validPieces: Data?
        var outstanding = 0
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
    }

    private var peers: [Peer] = []
    private var partial: [Int: [Int: Data]] = [:]
    private var downloadedBytes: Int64 = 0
    private var uploadedBytes: Int64 = 0
    private var lastDownBytes: Int64 = 0
    private var lastUpBytes: Int64 = 0
    private var running = false
    private var startedAnnounced = false
    private var completedAnnounced = false
    private var allTasks: [Task<Void, Never>] = []

    public init(torrent: TorrentInfo, rootURL: URL) {
        self.torrent = torrent
        self.rootURL = rootURL
        self.store = PieceStore(torrent: torrent, rootURL: rootURL)
        self.peerID = Self.makePeerID()
        self.port = Int.random(in: 6881...6999)
        self.progress = TransferProgress(downloadedBytes: 0, downloadedPieces: 0,
                                         totalPieces: torrent.numberOfPieces, uploadedBytes: 0,
                                         peers: 0, isDone: false)
    }

    deinit {
        for t in allTasks { t.cancel() }
        for p in peers { p.conn.close() }
    }

    public var isValid: Bool {
        store.validatedCount == torrent.numberOfPieces
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !running else { return }
        running = true
        emit(.state(.scanning))
        log("Scan: vorhandene Pieces werden geprüft…")
        if (try? store.prepareFiles()) == nil {
            emit(.error("Dateien konnten nicht angelegt werden"))
            emit(.state(.failed("Dateianlage fehlgeschlagen")))
            running = false
            return
        }
        for i in store.pendingPieceList() {
            if store.validatePiece(i) {
                store.setValid(i, true)
            }
        }
        let valid = store.validatedCount
        log("Scan: \(valid)/\(torrent.numberOfPieces) Pieces gültig.")
        emitProgress()
        if valid == torrent.numberOfPieces {
            emit(.state(.done))
            Task { await self.announce(event: "completed") }
            return
        }
        emit(.state(.downloading))
        allTasks = [
            Task { await self.trackerLoop() },
            Task { await self.requestLoop() },
            Task { await self.probeLoop() },
        ]
    }

    public func stop() {
        running = false
        for t in allTasks { t.cancel() }
        allTasks = []
        for p in peers {
            if !completedAnnounced { Task { await self.announceFor(p, event: "stopped") } }
            p.conn.close()
        }
        peers = []
        partial = [:]
        emit(.state(.paused))
    }

    public func recheck() async {
        log("Re-Check: alle Pieces werden neu validiert…")
        for i in store.pendingPieceList() where !store.isPieceValid(i) {
            if store.validatePiece(i) { store.setValid(i, true) }
        }
        emitProgress()
        log("Re-Check: \(store.validatedCount)/\(torrent.numberOfPieces) gültig.")
    }

    // MARK: - Events

    private func emit(_ event: EngineEvent) {
        switch event {
        case .state(let s): state = s
        case .error(let m): log(m)
        case .log: break
        case .progress: break
        }
    }

    private func emitProgress() {
        progress = TransferProgress(
            downloadedBytes: downloadedBytes,
            downloadedPieces: store.validatedCount,
            totalPieces: torrent.numberOfPieces,
            uploadedBytes: uploadedBytes,
            peers: peers.count,
            isDone: store.validatedCount == torrent.numberOfPieces
        )
    }

    private func log(_ s: String) {
        logs.append("[\(Date.now.formatted(date: .omitted, time: .standard))] \(s)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    // MARK: - Tracker

    private func trackerLoop() async {
        while running {
            var ok = false
            var interval: TimeInterval = 300
            for url in torrent.trackerURLs {
                let event: String?
                if completedAnnounced { event = nil }
                else if startedAnnounced { event = nil }
                else { event = "started"; startedAnnounced = true }

                do {
                    let res = try await TrackerClient.announce(
                        url: url, infoHash: torrent.infoHash, peerID: peerID, port: port,
                        uploaded: uploadedBytes, downloaded: downloadedBytes, event: event)
                    if let failure = res.failureReason {
                        log("Tracker \(url.host ?? ""): \(failure)")
                        continue
                    }
                    log("Tracker: \(res.peers.count) Peers erhalten (Intervall \(Int(res.interval))s)")
                    for addr in res.peers where peerExists(addr) == false {
                        Task { await self.connect(addr) }
                    }
                    ok = true
                    interval = res.interval
                    break
                } catch {
                    log("Tracker \(url.host ?? ""): \(error.localizedDescription)")
                }
            }
            if !ok { interval = 60 }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func announce(event: String) async {
        for url in torrent.trackerURLs {
            do {
                _ = try await TrackerClient.announce(url: url, infoHash: torrent.infoHash,
                    peerID: peerID, port: port, uploaded: uploadedBytes,
                    downloaded: downloadedBytes, event: event)
            } catch {}
        }
        completedAnnounced = (event == "completed")
    }

    private func announceFor(_ peer: Peer, event: String) async {
        for url in torrent.trackerURLs {
            do {
                _ = try await TrackerClient.announce(url: url, infoHash: torrent.infoHash,
                    peerID: peerID, port: port, uploaded: uploadedBytes,
                    downloaded: downloadedBytes, event: event)
            } catch {}
        }
    }

    // MARK: - Peers

    private func peerExists(_ addr: PeerAddress) -> Bool {
        peers.contains { $0.addr == addr }
    }

    private func connect(_ addr: PeerAddress) async {
        guard running, peers.count < Self.maxPeers, !peerExists(addr) else { return }
        let conn = PeerConnection(infoHash: torrent.infoHash, peerID: peerID)
        let events = conn.makeStream()
        conn.start(host: addr.ip, port: addr.port)
        let peer = Peer(addr: addr, conn: conn)
        peers.append(peer)
        log("Peer \(addr.label): verbunden.")
        emitProgress()
        await peerLoop(peer: peer, events: events)
    }

    private func peerLoop(peer: Peer, events: AsyncThrowingStream<PeerEvent, Error>) async {
        defer {
            if peers.contains(where: { $0.id == peer.id }) {
                log("Peer \(peer.addr.label): getrennt.")
                disconnect(peer)
            }
        }
        do {
            for try await event in events {
                switch event {
                case .handshake(let peerIdStr):
                    log("Peer \(peer.addr.label): Handshake OK (\(peerIdStr.prefix(10))…)")
                    // Wir sind interessiert und zeigen unsere validierten Pieces.
                    send(peer, PeerConnection.frame(2))
                    send(peer, PeerConnection.frame(5, store.validBitfield()))
                case .message(let data):
                    handle(peer, data)
                }
            }
        } catch {
            log("Peer \(peer.addr.label): \(error.localizedDescription)")
        }
    }

    private func disconnect(_ peer: Peer) {
        peers.removeAll { $0.id == peer.id }
        emitProgress()
    }

    private func handle(_ peer: Peer, _ data: Data) {
        switch PeerMessage.parse(data) {
        case .keepAlive, .unknown:
            break
        case .choke:
            peer.outstanding = 0
        case .unchoke, .interested, .notInterested:
            break
        case .have(let p):
            peer.setHas(p)
        case .bitfield(let b):
            peer.validPieces = b
        case .piece(let p, let o, let d):
            peer.outstanding = max(0, peer.outstanding - 1)
            assemble(peer: peer, piece: p, offset: o, data: d)
        case .request(let p, let o, let l):
            upload(peer: peer, piece: p, offset: o, length: l)
        case .cancel:
            break
        case .ping:
            send(peer, PeerConnection.frame(0x11)) // pong
        case .pong:
            break
        case .extensionMessage:
            break
        }
    }

    private func send(_ peer: Peer, _ frame: Data) {
        do { try peer.conn.send(frame) }
        catch { log("Sendfehler (\(peer.addr.label)): \(error.localizedDescription)") }
    }

    // MARK: - Download

    /// Partials zusammenfügen → schreiben → SHA-1-Prüfung → Bitset.
    private func assemble(peer: Peer, piece: Int, offset: Int, data: Data) {
        guard (0..<torrent.numberOfPieces).contains(piece) else { return }
        let pLen = store.pieceLength(piece)
        guard pLen > 0, offset >= 0, offset + data.count <= pLen else { return }
        partial[piece, default: [:]][offset] = data

        guard let full = reconstruct(piece: piece) else { return }
        guard store.writePieceBytes(full, index: piece) else {
            log("Schreibfehler Piece \(piece)")
            partial[piece] = nil
            return
        }
        guard store.validatePiece(piece) else {
            log("Piece \(piece): Hash ungültig, verworfen.")
            partial[piece] = nil
            return
        }
        partial[piece] = nil
        store.setValid(piece, true)
        downloadedBytes += Int64(pLen)
        log("Piece \(piece)/\(torrent.numberOfPieces - 1) valid.")
        broadcastHave(piece)
        emitProgress()

        if store.validatedCount == torrent.numberOfPieces {
            emit(.state(.done))
            Task { await self.announce(event: "completed") }
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

    /// Request-Loop: rare-first, max 4 offene Requests pro Peer.
    private func requestLoop() async {
        while running {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for peer in peers {
                while peer.outstanding < Self.maxConcurrentPerPeer {
                    guard let piece = nextPiece(peer: peer) else { break }
                    guard let offset = nextOffset(piece: piece) else { break }
                    let len = min(Self.requestLength, store.pieceLength(piece) - offset)
                    var payload = Data()
                    appendBE32(&payload, piece); appendBE32(&payload, offset); appendBE32(&payload, len)
                    send(peer, PeerConnection.frame(6, payload))
                    peer.outstanding += 1
                }
            }
        }
    }

    /// Stück mit den wenigsten Haltern (rare-first), bevorzugt das, das schon im Partial ist.
    private func nextPiece(peer: Peer) -> Int? {
        // Fortsetzung laufender Pieces hat Vorrang.
        let inProgress = partial.keys.filter { peer.has($0) }
        if let p = inProgress.randomElement() { return p }
        let pending = store.pendingPieceList().filter { partial[$0] == nil && peer.has($0) }
        guard !pending.isEmpty else { return nil }
        let minHolders = pending.map { holders(of: $0) }.min() ?? 0
        return pending.filter { holders(of: $0) == minHolders }.randomElement()
    }

    private func holders(of piece: Int) -> Int {
        peers.filter { $0.has(piece) }.count
    }

    private func nextOffset(piece: Int) -> Int? {
        let pLen = store.pieceLength(piece)
        var off = 0
        while off < pLen {
            if partial[piece]?[off] == nil { return off }
            off += min(Self.requestLength, pLen - off)
        }
        return nil
    }

    // MARK: - Upload

    private func upload(peer: Peer, piece: Int, offset: Int, length: Int) {
        guard (0..<torrent.numberOfPieces).contains(piece) else {
            send(peer, PeerConnection.frame(0))
            return
        }
        let pLen = store.pieceLength(piece)
        guard length > 0, offset >= 0, offset + length <= pLen else {
            send(peer, PeerConnection.frame(0))
            return
        }
        guard store.isPieceValid(piece) else {
            send(peer, PeerConnection.frame(0))
            return
        }
        let start = piece * torrent.pieceLength + offset
        guard let data = store.readSlice(offset: start, length: length) else {
            send(peer, PeerConnection.frame(0))
            return
        }
        var payload = Data()
        appendBE32(&payload, piece); appendBE32(&payload, offset)
        payload.append(data)
        send(peer, PeerConnection.frame(7, payload))
        uploadedBytes += Int64(length)
    }

    // MARK: - Keepalive + Speed

    private func probeLoop() async {
        while running {
            try? await Task.sleep(for: .seconds(5))
            for peer in peers {
                send(peer, PeerConnection.frame(0x10)) // ping
            }
            let downSpeed = max(0, (downloadedBytes - lastDownBytes) / 5)
            let upSpeed = max(0, (uploadedBytes - lastUpBytes) / 5)
            lastDownBytes = downloadedBytes
            lastUpBytes = uploadedBytes
            progress.downSpeed = downSpeed
            progress.upSpeed = upSpeed
        }
    }

    // MARK: - PeerID

    private static func makePeerID() -> Data {
        var id = Data("-MT0001-".data(using: .utf8)!)
        var seed = Data(repeating: 0, count: 16)
        for i in 0..<16 { seed[i] = UInt8.random(in: 0...255) }
        id.append(seed)
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
