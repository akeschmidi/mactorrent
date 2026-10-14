import Foundation
import Network

/// BEPEF-Tracker-Client: announce über HTTP(S), bencoded Query.
public struct TrackerClient {
    public struct Result: Sendable {
        public var peers: [PeerAddress]
        public var interval: TimeInterval
        public var failureReason: String?
    }

    /// Ruft einen Tracker an. Query als raw bencoded Data (Tracker-Anfrage).
    public static func announce(
        url: URL,
        infoHash: Data,
        peerID: Data,
        port: Int,
        uploaded: Int64,
        downloaded: Int64,
        event: String?
    ) async throws -> Result {
        var query: [String: Any] = [
            "info_hash": infoHash,
            "peer_id": peerID,
            "port": port,
            "uploaded": uploaded,
            "downloaded": downloaded,
            "num_want": 100,
            "compact": 1
        ]
        if let event { query["event"] = event }
        let queryData = try BB.encode(query)

        var base = url.absoluteString
        base += (base.contains("?") ? "&" : "?")
        base += percentEncodeRaw(queryData)

        guard let requestURL = URL(string: base) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)

        // Normal: bencoded Dict. Fallback: HTTP-Text ("flood", "No peers", peer-Liste).
        if let root = try? BB.decodeTolerant(data), let dict = root as? [String: Any] {
            if let failure = BB.string(dict["failure_reason"]) {
                return Result(peers: [], interval: 120, failureReason: failure)
            }
            let interval = TimeInterval(BB.int(dict["interval"]) ?? 300)
            var peers: [PeerAddress] = []
            if let compact = BB.data(dict["peers"]) {
                if compact.count >= 6, compact.count % 6 == 0 {
                    let b = Array(compact)
                    for i in stride(from: 0, to: compact.count, by: 6) {
                        let ip = "\(b[i]).\(b[i + 1]).\(b[i + 2]).\(b[i + 3])"
                        let p = (Int(b[i + 4]) << 8) | Int(b[i + 5])
                        peers.append(PeerAddress(ip: ip, port: p))
                    }
                }
            } else if let list = dict["peers"] as? [Any] {
                for item in list {
                    if let d = item as? [String: Any],
                       let ip = BB.string(d["ip"]), let p = BB.int(d["port"]) {
                        peers.append(PeerAddress(ip: ip, port: p))
                    } else if let s = BB.string(item), let addr = parseCompactString(s) {
                        peers.append(addr)
                    }
                }
            }
            return Result(peers: peers, interval: interval, failureReason: nil)
        }

        // Text-Antwort.
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.lowercased().contains("flood") {
            return Result(peers: [], interval: 300, failureReason: "flood limit")
        }
        if text.lowercased().contains("no peers") {
            return Result(peers: [], interval: 300, failureReason: nil)
        }
        return Result(peers: [], interval: 120, failureReason: "ungültige Antwort (\(text.prefix(60)))")
    }

    private static func parseCompactString(_ s: String) -> PeerAddress? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return nil }
        return PeerAddress(ip: String(parts[0]), port: port)
    }

    /// Percent-Encoding nach RFC 3986 (nur unreservierte Zeichen bleiben).
    private static func percentEncodeRaw(_ data: Data) -> String {
        data.map { byte in
            let c = Character(UnicodeScalar(byte))
            return (c.isLetter || c.isNumber || "-._~".contains(c)) ? String(c) : String(format: "%%%02X", byte)
        }.joined()
    }
}
