import Foundation

/// Ein `magnet:?xt=urn:btih:…`-Link.
public struct MagnetLink: Sendable {
    public let infoHash: Data
    public let name: String?
    public let trackers: [URL]
    public var infoHashHex: String { infoHash.hex }

    public init?(_ string: String) {
        guard let comps = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "magnet" else { return nil }
        var hash: Data?
        var name: String?
        var trackers: [URL] = []
        for item in comps.queryItems ?? [] {
            guard let v = item.value else { continue }
            switch item.name.lowercased() {
            case "xt":
                if v.lowercased().hasPrefix("urn:btih:") { hash = Self.decodeHash(String(v.dropFirst(9))) }
            case "dn": name = v
            case "tr": if let u = URL(string: v), !trackers.contains(u) { trackers.append(u) }
            default: break
            }
        }
        guard let hash else { return nil }
        self.infoHash = hash
        self.name = name
        self.trackers = trackers
    }

    /// 40 Hex-Zeichen oder 32 Base32-Zeichen → 20 Bytes.
    static func decodeHash(_ s: String) -> Data? {
        if s.count == 40 {
            var out = Data()
            var it = s.makeIterator()
            while let a = it.next(), let b = it.next() {
                guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
                out.append(byte)
            }
            return out.count == 20 ? out : nil
        }
        guard s.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, acc = 0
        var out = Data()
        for ch in s.uppercased() {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 0xFF)) }
        }
        return out.count == 20 ? out : nil
    }
}
