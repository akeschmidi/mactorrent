import Foundation
import Network

/// Tracker-Announce über HTTP. Query ist application/x-www-form-urlencoded (BEP 3),
/// die Antwort ist bencoded.
public struct TrackerClient {
    public struct Result: Sendable {
        public var peers: [PeerAddress]
        public var interval: TimeInterval
        public var failureReason: String?
    }

    /// Ruft einen Tracker an. `info_hash` und `peer_id` gehen als rohe 20 Bytes in die Query.
    public static func announce(
        url: URL,
        infoHash: Data,
        peerID: Data,
        port: Int,
        uploaded: Int64,
        downloaded: Int64,
        left: Int64,
        event: String?
    ) async throws -> Result {
        if !NetworkPolicy.shared.allowLocalTrackers, NetworkPolicy.isLocalHost(url.host) {
            throw HTTPClient.HTTPError(message: String(localized: "Tracker im lokalen Netz blockiert (\(url.host ?? ""))", bundle: .main))
        }
        // Anonymer Modus: dem Tracker keine Transfer-Zahlen verraten (er braucht nur `left`).
        let anon = NetworkPolicy.shared.anonymous
        let uploaded = anon ? 0 : uploaded, downloaded = anon ? 0 : downloaded
        if url.scheme?.lowercased() == "udp" {
            return try await UDPTracker.announce(url: url, infoHash: infoHash, peerID: peerID, port: port,
                                                 uploaded: uploaded, downloaded: downloaded, left: left, event: event)
        }
        var items = [
            "info_hash=\(percentEncodeRaw(infoHash))",
            "peer_id=\(percentEncodeRaw(peerID))",
            "port=\(port)",
            "uploaded=\(uploaded)",
            "downloaded=\(downloaded)",
            "left=\(max(0, left))",
            "compact=1",
            "numwant=100"
        ]
        if let event { items.append("event=\(event)") }
        let extra = items.joined(separator: "&")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + extra
        } else {
            components.percentEncodedQuery = extra
        }
        guard let requestURL = components.url else {
            throw URLError(.badURL)
        }
        let data = try await HTTPClient.get(requestURL)

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
        return Result(peers: [], interval: 120, failureReason: String(localized: "ungültige Antwort (\(text.prefix(60)))", bundle: .main))
    }

    private static func parseCompactString(_ s: String) -> PeerAddress? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return nil }
        return PeerAddress(ip: String(parts[0]), port: port)
    }

    /// Percent-Encoding nach RFC 3986. Nur ASCII-Unreserved bleibt roh.
    /// `Character.isLetter` wäre hier falsch: Byte 0xF6 ist „ö“ und würde den Info-Hash zerstören.
    private static func percentEncodeRaw(_ data: Data) -> String {
        data.map { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
