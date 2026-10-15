import Foundation
import Network

/// UDP-Tracker (BEP 15): connect → announce. Die meisten Magnet-Links nennen nur udp://-Tracker.
enum UDPTracker {
    static func announce(url: URL, infoHash: Data, peerID: Data, port: Int,
                         uploaded: Int64, downloaded: Int64, left: Int64, event: String?) async throws -> TrackerClient.Result {
        guard let host = url.host, let p = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else { throw URLError(.badURL) }
        guard !NetworkPolicy.shared.isBlocked else { throw URLError(.notConnectedToInternet) }
        let conn = NWConnection(host: .init(host), port: p, using: NetworkPolicy.shared.parameters(.udp))
        let io = UDPIO(conn)
        defer { conn.cancel() }

        var tx = UInt32.random(in: .min ... .max)
        var req = Data()
        req.be64(0x41727101980); req.be32(0); req.be32(tx)
        let r1 = try await io.exchange(req)
        guard r1.count >= 16, r1.u32(0) == 0, r1.u32(4) == tx else { throw URLError(.cannotParseResponse) }
        let connectionID = r1.subdata(in: 8..<16)

        tx = UInt32.random(in: .min ... .max)
        var a = connectionID
        a.be32(1); a.be32(tx)
        a.append(infoHash); a.append(peerID)
        a.be64(UInt64(max(0, downloaded))); a.be64(UInt64(max(0, left))); a.be64(UInt64(max(0, uploaded)))
        a.be32(["completed": 1, "started": 2, "stopped": 3][event ?? ""] ?? 0)
        a.be32(0); a.be32(UInt32.random(in: .min ... .max)); a.be32(0xFFFF_FFFF)
        a.append(UInt8(port >> 8)); a.append(UInt8(port & 0xFF))
        let r2 = try await io.exchange(a)
        if r2.count >= 8, r2.u32(0) == 3 {
            return .init(peers: [], interval: 120, failureReason: String(decoding: r2.dropFirst(8), as: UTF8.self))
        }
        guard r2.count >= 20, r2.u32(0) == 1, r2.u32(4) == tx else { throw URLError(.cannotParseResponse) }
        var peers: [PeerAddress] = []
        let b = Array(r2)
        for i in stride(from: 20, to: b.count - 5, by: 6) {
            peers.append(PeerAddress(ip: "\(b[i]).\(b[i+1]).\(b[i+2]).\(b[i+3])", port: Int(b[i+4]) << 8 | Int(b[i+5])))
        }
        return .init(peers: peers, interval: TimeInterval(max(60, Int(r2.u32(8)))), failureReason: nil)
    }
}

/// Ein Request, eine Antwort, mit Timeout und zwei Wiederholungen (UDP verliert Pakete).
final class UDPIO: @unchecked Sendable {
    let conn: NWConnection
    private var started = false
    init(_ c: NWConnection) { conn = c }

    func exchange(_ packet: Data, timeout: TimeInterval = 5, tries: Int = 3) async throws -> Data {
        if !started { started = true; conn.start(queue: .global()) }
        for _ in 0..<tries {
            conn.send(content: packet, completion: .contentProcessed { _ in })
            let got: Data? = await withCheckedContinuation { cont in
                let once = Once()
                conn.receiveMessage { data, _, _, _ in if once.fire() { cont.resume(returning: data) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if once.fire() { cont.resume(returning: nil) } }
            }
            if let got, !got.isEmpty { return got }
        }
        throw URLError(.timedOut)
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private extension Data {
    mutating func be32(_ v: UInt32) { for s in [24, 16, 8, 0] { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    mutating func be64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(s)) & 0xFF)) } }
    func u32(_ i: Int) -> UInt32 {
        let b = Array(self)
        return UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3])
    }
}
