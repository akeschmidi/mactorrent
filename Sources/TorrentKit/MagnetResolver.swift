import Foundation
import CryptoKit

public enum MagnetError: Error, LocalizedError {
    case timeout
    case mismatch
    public var errorDescription: String? {
        switch self {
        case .timeout: String(localized: "Keine Metadaten gefunden (keine erreichbaren Peers)", bundle: .main)
        case .mismatch: String(localized: "Metadaten passen nicht zum Info-Hash", bundle: .main)
        }
    }
}

/// Holt die Torrent-Metadaten zu einem Magnet-Link (BEP 9 über BEP 10): Tracker fragen,
/// Peers verbinden, `ut_metadata`-Stücke sammeln, per SHA-1 gegen den Info-Hash prüfen.
/// Ergebnis sind die Bytes einer .torrent-Datei. ponytail: nur Tracker, kein DHT.
@MainActor
public final class MagnetResolver {
    private static let pieceSize = 16 * 1024
    private static let localMetadataID = 1

    private let link: MagnetLink
    private let peerID: Data
    private var trackers: [URL]
    private var seen = Set<PeerAddress>()
    private var size = 0
    private var pieces: [Int: Data] = [:]
    private var result: Data?
    private var tasks: [Task<Void, Never>] = []
    private let dht: DHT?
    public var infoHash: Data { link.infoHash }
    public private(set) var status = "Suche Peers…"

    public init(link: MagnetLink, extraTrackers: [URL]? = nil, dht: DHT? = nil) {
        self.link = link
        self.dht = dht
        var t = link.trackers
        // Anonymer Modus: keine öffentlichen Zusatz-Tracker (sie würden Info-Hash + IP erfahren).
        let extra = extraTrackers ?? (NetworkPolicy.shared.anonymous ? [] : TorrentEngine.publicTrackers)
        for u in extra where !t.contains(u) { t.append(u) }
        self.trackers = t
        self.peerID = TorrentEngine.makePeerID()
    }

    public func resolve(timeout: TimeInterval = 120) async throws -> Data {
        tasks.append(Task { await self.trackerLoop() })
        if dht != nil { tasks.append(Task { await self.dhtLoop() }) }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        tasks.forEach { $0.cancel() }
        guard let result else { throw Task.isCancelled ? CancellationError() : MagnetError.timeout }
        return result
    }

    private func trackerLoop() async {
        while result == nil && !Task.isCancelled {
            for url in trackers {
                guard let res = try? await TrackerClient.announce(
                    url: url, infoHash: link.infoHash, peerID: peerID, port: 6881,
                    uploaded: 0, downloaded: 0, left: 1 << 30, event: "started") else { continue }
                found(res.peers)
            }
            try? await Task.sleep(for: .seconds(20))
        }
    }

    private func found(_ peers: [PeerAddress]) {
        for addr in peers where seen.count < 300 && seen.insert(addr).inserted {
            status = "Peers gefunden: \(seen.count)"
            tasks.append(Task { await self.fetch(from: addr) })
        }
    }

    /// Ohne Tracker (oder zusätzlich) per DHT nach Peers suchen, alle 20 s neu.
    private func dhtLoop() async {
        while result == nil && !Task.isCancelled {
            await dht?.lookup(infoHash: link.infoHash) { [weak self] peers in
                Task { @MainActor in self?.found(peers) }
            }
            try? await Task.sleep(for: .seconds(20))
        }
    }

    private func fetch(from addr: PeerAddress) async {
        // Nicht zu viele gleichzeitig: ältere Tasks sind meist schon beendet oder tot.
        let conn = PeerConnection(infoHash: link.infoHash, peerID: peerID, extensions: true)
        let events = conn.makeStream()
        conn.start(host: addr.ip, port: addr.port)
        defer { conn.close() }
        do {
            for try await event in events {
                if result != nil { return }
                switch event {
                case .handshake:
                    let hello = try BB.encode(["m": ["ut_metadata": Self.localMetadataID]] as [String: Any])
                    try conn.send(PeerConnection.frame(20, Data([0]) + hello))
                case .message(let d):
                    guard d.count >= 2, d[d.startIndex] == 20 else { continue }
                    let body = Data(d.dropFirst(2))
                    if d[d.startIndex + 1] == 0 {
                        try handleHello(body, conn)
                    } else {
                        handleData(body)
                    }
                }
            }
        } catch {}
    }

    private func handleHello(_ body: Data, _ conn: PeerConnection) throws {
        guard let dict = try BB.decodeTolerant(body) as? [String: Any],
              let m = dict["m"] as? [String: Any],
              let remote = BB.int(m["ut_metadata"]), (1...255).contains(remote),
              let total = BB.int(dict["metadata_size"]), total > 0, total <= 16 * 1024 * 1024 else { return }
        if size == 0 { size = total }
        guard total == size else { return }
        status = "Lade Metadaten…"
        for i in 0..<((size + Self.pieceSize - 1) / Self.pieceSize) where pieces[i] == nil {
            let req = try BB.encode(["msg_type": 0, "piece": i] as [String: Any])
            try conn.send(PeerConnection.frame(20, Data([UInt8(truncatingIfNeeded: remote)]) + req))
        }
    }

    private func handleData(_ body: Data) {
        guard let dict = (try? BB.decodeTolerant(body)) as? [String: Any],
              BB.int(dict["msg_type"]) == 1, let idx = BB.int(dict["piece"]),
              let headerLen = (try? BB.encode(dict))?.count, body.count > headerLen else { return }
        pieces[idx] = Data(body.dropFirst(headerLen))
        let count = (size + Self.pieceSize - 1) / Self.pieceSize
        guard size > 0, pieces.count == count else { return }
        let raw = (0..<count).reduce(into: Data()) { $0.append(pieces[$1] ?? Data()) }
        guard Data(Insecure.SHA1.hash(data: raw)) == link.infoHash else {
            pieces = [:] // ein Peer hat Müll geliefert → neu sammeln
            return
        }
        result = Self.makeTorrentFile(info: raw, trackers: trackers)
    }

    /// Verpackt das rohe info-Dict (Hash bleibt byte-genau) in eine .torrent-Datei.
    static func makeTorrentFile(info: Data, trackers: [URL]) -> Data {
        func b(_ s: String) -> Data { Data("\(s.utf8.count):\(s)".utf8) }
        var out = Data("d".utf8)
        if let first = trackers.first {
            out += b("announce") + b(first.absoluteString)
            out += b("announce-list") + Data("l".utf8)
            for t in trackers { out += Data("l".utf8) + b(t.absoluteString) + Data("e".utf8) }
            out += Data("e".utf8)
        }
        out += b("info") + info + Data("e".utf8)
        return out
    }
}
