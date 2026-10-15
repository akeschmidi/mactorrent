import XCTest
import CryptoKit
@testable import TorrentKit

/// Lädt ein Stück über einen lokalen Tracker und einen BEP-3-Peer.
/// Fällt der Test, spricht die App kein BitTorrent, das ein normaler Peer beantwortet.
@MainActor
final class DownloadTests: XCTestCase {
    override func setUp() { NetworkPolicy.shared.allowLocalTrackers = true } // Tests nutzen 127.0.0.1-Tracker

    func testPeerMessageIDsMatchBEP3() {
        XCTAssertEqual(describe(PeerMessage.parse(Data([0]))), "choke")
        XCTAssertEqual(describe(PeerMessage.parse(Data([1]))), "unchoke")
        XCTAssertEqual(describe(PeerMessage.parse(Data([2]))), "interested")
        XCTAssertEqual(describe(PeerMessage.parse(Data([3]))), "notInterested")
        XCTAssertEqual(describe(PeerMessage.parse(Data([4, 0, 0, 0, 3]))), "have:3")
        XCTAssertEqual(describe(PeerMessage.parse(Data([5, 0x80]))), "bitfield:1")
        if case .piece(let piece, let offset, let data) = PeerMessage.parse(Data([7, 0, 0, 0, 1, 0, 0, 0, 4, 9, 9])) {
            XCTAssertEqual(piece, 1)
            XCTAssertEqual(offset, 4)
            XCTAssertEqual(data, Data([9, 9]))
        } else {
            XCTFail("piece-Message nicht erkannt")
        }
    }

    func testOutgoingHandshakeIsBEP3() throws {
        let hash = Data(repeating: 0x22, count: 20)
        let peerID = Data(repeating: 0x11, count: 20)
        let (lfd, port) = try Loopback.bind()
        defer { Darwin.close(lfd) }
        let conn = PeerConnection(infoHash: hash, peerID: peerID)
        conn.start(host: "127.0.0.1", port: Int(port))
        let cfd = try Loopback.accept(lfd, timeout: 3)
        defer { Darwin.close(cfd) }
        let got = try Loopback.readSome(cfd, timeout: 2)
        XCTAssertEqual(got.count, 68, "Handshake ist \(got.count) Bytes, BEP 3 verlangt 68")
        guard got.count >= 68 else { return }
        XCTAssertEqual(got[0], 19)
        XCTAssertEqual(Data(got[1..<20]), Data("BitTorrent protocol".utf8))
        XCTAssertEqual(Data(got[28..<48]), hash)
        XCTAssertEqual(Data(got[48..<68]), peerID)
    }

    func testStandardHandshakeIsAccepted() async throws {
        let hash = Data(repeating: 0x22, count: 20)
        let localID = Data(repeating: 0x11, count: 20)
        let remoteID = Data(repeating: 0x33, count: 20)
        let (lfd, port) = try Loopback.bind()
        defer { Darwin.close(lfd) }
        let conn = PeerConnection(infoHash: hash, peerID: localID)
        let stream = conn.makeStream()
        let box = ResultBox()
        let collect = Task {
            do {
                for try await event in stream {
                    if case .handshake = event { box.handshake = true }
                }
            } catch {
                box.error = String(describing: error)
            }
        }
        conn.start(host: "127.0.0.1", port: Int(port))
        let cfd = try Loopback.accept(lfd, timeout: 3)
        defer { Darwin.close(cfd) }
        _ = try Loopback.readExactly(cfd, 68, timeout: 2)
        try Loopback.writeAll(cfd, Loopback.handshake(infoHash: hash, peerID: remoteID))
        let deadline = Date().addingTimeInterval(3)
        while !box.handshake && box.error == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        collect.cancel()
        conn.close()
        XCTAssertTrue(box.handshake, box.error ?? "Handshake abgelehnt")
    }

    func testAnnounceQueryCarriesInfoHash() async throws {
        // 0xF6 ist in Swift ein Buchstabe („ö“). Der Hash muss trotzdem als %F6 rausgehen.
        let hash = Data([0x97, 0x46, 0x68, 0xF6] + Array(repeating: 0xAB, count: 16))
        let peerID = Data("-MT0001-aaaaaaaaaaaa".utf8)
        let (lfd, port) = try Loopback.bind()
        defer { Darwin.close(lfd) }
        let captured = RequestBox()
        let body = Self.compactPeers(port: 6881)
        let serve = Task.detached {
            try? Loopback.serveHTTP(lfd, captured: captured, body: body)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/announce")!
        let res = try await TrackerClient.announce(
            url: url, infoHash: hash, peerID: peerID, port: 6881,
            uploaded: 0, downloaded: 0, left: 100, event: "started")
        serve.cancel()
        let line = captured.line
        XCTAssertTrue(line.contains("info_hash=%97Fh%F6" + String(repeating: "%AB", count: 16)), line)
        XCTAssertFalse(line.contains("%25"), line)
        XCTAssertFalse(line.contains("%C3"), line)
        XCTAssertTrue(line.contains("peer_id=-MT0001-aaaaaaaaaaaa"), line)
        XCTAssertTrue(line.contains("event=started"), line)
        XCTAssertTrue(line.contains("left=100"), line)
        XCTAssertTrue(line.contains("compact=1"), line)
        XCTAssertFalse(line.contains("d8:"), "Query ist ein bencode-Blob: \(line)")
        XCTAssertEqual(res.peers, [PeerAddress(ip: "127.0.0.1", port: 6881)])
    }

    func testEngineDownloadsFileFromLocalPeer() async throws {
        // Zwei Blöcke in einem Piece: die ersten Requests müssen verschiedene Offsets haben.
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0) })
        let (trackerFD, trackerPort) = try Loopback.bind()
        defer { Darwin.close(trackerFD) }
        let (peerFD, peerPort) = try Loopback.bind()
        defer { Darwin.close(peerFD) }

        let announce = "http://127.0.0.1:\(trackerPort)/announce"
        let torrent = try Self.makeTorrent(announce: announce, name: "payload.bin", payload: payload, pieceLength: 32_768)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactorrent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let peersBody = Self.compactPeers(port: peerPort)
        let offsets = OffsetBox()
        let http = Task.detached {
            try? Loopback.serveHTTP(trackerFD, captured: RequestBox(), body: peersBody)
        }
        let seeder = Task.detached {
            try? Loopback.seed(peerFD, infoHash: torrent.infoHash, payload: payload, offsets: offsets)
        }
        defer {
            http.cancel()
            seeder.cancel()
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let engine = TorrentEngine(torrent: torrent, rootURL: root)
        engine.allowPublicTrackers = false
        await engine.start()
        let deadline = Date().addingTimeInterval(8)
        while engine.state != .done && Date() < deadline {
            if case .failed = engine.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let logs = engine.logs.joined(separator: "\n")
        XCTAssertEqual(engine.state, .done, logs)
        let got = try Data(contentsOf: root.appendingPathComponent("payload.bin"))
        XCTAssertEqual(got, payload)
        XCTAssertGreaterThanOrEqual(offsets.values.count, 2, logs)
        XCTAssertEqual(Set(offsets.values.prefix(2)), Set([0, 16_384]), "gleiche Offsets: \(offsets.values)")
        engine.stop()
        // Nach Pause müssen die Raten 0 bleiben (ein letzter Tick darf sie nicht neu setzen).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(engine.progress.downSpeed, 0)
        XCTAssertEqual(engine.progress.upSpeed, 0)
    }

    func testEngineSeedsToIncomingPeer() async throws {
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let torrent = try Self.makeTorrent(announce: "http://127.0.0.1:1/announce", name: "seed.bin", payload: payload, pieceLength: 32_768)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactorrent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try payload.write(to: root.appendingPathComponent("seed.bin"))

        let engine = TorrentEngine(torrent: torrent, rootURL: root)
        engine.allowPublicTrackers = false
        await engine.start()
        defer { engine.stop() }
        XCTAssertEqual(engine.state, .done)
        XCTAssertNotEqual(engine.listenPort, 0)

        let client = PeerConnection(infoHash: torrent.infoHash, peerID: Data(repeating: 7, count: 20))
        let events = client.makeStream()
        client.start(host: "127.0.0.1", port: engine.listenPort)
        let got = OffsetBox()  // sammelt die Länge des empfangenen Blocks
        let reader = Task {
            for try await e in events {
                switch e {
                case .handshake:
                    try client.send(PeerConnection.frame(2))
                case .message(let d):
                    switch PeerMessage.parse(d) {
                    case .unchoke:
                        var req = Data(); appendBE32(&req, 0); appendBE32(&req, 0); appendBE32(&req, 16_384)
                        try client.send(PeerConnection.frame(6, req))
                    case .piece(_, _, let block):
                        XCTAssertEqual(block, payload.prefix(16_384))
                        got.values.append(block.count)
                        return
                    default: break
                    }
                }
            }
        }
        let deadline = Date().addingTimeInterval(8)
        while got.values.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        reader.cancel(); client.close()
        XCTAssertEqual(got.values, [16_384], engine.logs.joined(separator: "\n"))
    }

    private static func makeTorrent(announce: String, name: String, payload: Data, pieceLength: Int = 16_384) throws -> TorrentInfo {
        var hashes = Data()
        var off = 0
        while off < payload.count {
            let end = min(off + pieceLength, payload.count)
            hashes.append(Data(Insecure.SHA1.hash(data: payload[off..<end])))
            off = end
        }
        let info: [String: Any] = [
            "length": payload.count,
            "name": name,
            "piece length": pieceLength,
            "pieces": hashes
        ]
        let data = try BB.encode(["announce": announce, "info": info] as [String: Any])
        return try TorrentParser.parse(data)
    }

    private static func compactPeers(port: UInt16) -> Data {
        let peers = Data([127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF)])
        return (try? BB.encode(["interval": 60, "peers": peers] as [String: Any])) ?? Data()
    }

    private func describe(_ message: PeerMessage) -> String {
        switch message {
        case .keepAlive: return "keepAlive"
        case .choke: return "choke"
        case .unchoke: return "unchoke"
        case .interested: return "interested"
        case .notInterested: return "notInterested"
        case .have(let piece): return "have:\(piece)"
        case .bitfield(let data): return "bitfield:\(data.count)"
        case .piece: return "piece"
        case .request: return "request"
        case .cancel: return "cancel"
        case .ping: return "ping"
        case .pong: return "pong"
        case .extensionMessage(let id): return "ext:\(id)"
        case .unknown: return "unknown"
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var handshake = false
    var error: String?
}

private final class RequestBox: @unchecked Sendable {
    var line = ""
}

private final class OffsetBox: @unchecked Sendable {
    var values: [Int] = []
}

private enum Loopback {
    static func bind() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { Darwin.close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if listen(fd, 8) != 0 { Darwin.close(fd); throw POSIXError(.EIO) }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if named != 0 { Darwin.close(fd); throw POSIXError(.EIO) }
        return (fd, UInt16(bigEndian: got.sin_port))
    }

    static func accept(_ fd: Int32, timeout: Double) throws -> Int32 {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, Int32(timeout * 1000)) <= 0 { throw POSIXError(.ETIMEDOUT) }
        let cfd = Darwin.accept(fd, nil, nil)
        if cfd < 0 { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return cfd
    }

    static func readSome(_ fd: Int32, timeout: Double) throws -> Data {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var tmp = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(fd, &tmp, tmp.count)
        if n <= 0 { throw POSIXError(.ETIMEDOUT) }
        return Data(tmp.prefix(n))
    }

    static func readExactly(_ fd: Int32, _ count: Int, timeout: Double) throws -> Data {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        while out.count < count {
            var tmp = [UInt8](repeating: 0, count: count - out.count)
            let n = Darwin.read(fd, &tmp, tmp.count)
            if n <= 0 { throw POSIXError(.ETIMEDOUT) }
            out.append(tmp, count: n)
        }
        return out
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        var rest = data
        while !rest.isEmpty {
            let n = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, rest.count) }
            if n <= 0 { throw POSIXError(.EIO) }
            rest.removeFirst(n)
        }
    }

    static func handshake(infoHash: Data, peerID: Data) -> Data {
        var hs = Data([19])
        hs.append(Data("BitTorrent protocol".utf8))
        hs.append(Data(count: 8))
        hs.append(infoHash)
        hs.append(peerID)
        return hs
    }

    static func serveHTTP(_ fd: Int32, captured: RequestBox, body: Data) throws {
        let cfd = try accept(fd, timeout: 5)
        defer { Darwin.close(cfd) }
        let header = try readUntilHeader(cfd)
        captured.line = String(decoding: header, as: UTF8.self)
        var resp = Data("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        resp.append(body)
        try writeAll(cfd, resp)
    }

    /// Seeder: Standard-Handshake, Bitfield, Unchoke nach Interested, Pieces auf Request.
    static func seed(_ fd: Int32, infoHash: Data, payload: Data, offsets: OffsetBox? = nil) throws {
        let cfd = try accept(fd, timeout: 5)
        defer { Darwin.close(cfd) }
        var buf = Data()
        func take(_ n: Int) throws -> Data {
            while buf.count < n {
                var tmp = [UInt8](repeating: 0, count: 4096)
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let r = Darwin.read(cfd, &tmp, tmp.count)
                if r <= 0 { throw POSIXError(.ETIMEDOUT) }
                buf.append(tmp, count: r)
            }
            let out = Data(buf.prefix(n))
            buf.removeFirst(n)
            return out
        }
        _ = try take(68)
        let remote = Data(repeating: 0x44, count: 20)
        try writeAll(cfd, handshake(infoHash: infoHash, peerID: remote))
        try writeAll(cfd, frame(5, Data([0x80])))
        var sentUnchoke = false
        while true {
            let lenData = try take(4)
            let len = Int(lenData[0]) << 24 | Int(lenData[1]) << 16 | Int(lenData[2]) << 8 | Int(lenData[3])
            if len == 0 { continue }
            if len > 1_048_576 { return }
            let msg = try take(len)
            guard let id = msg.first else { continue }
            if id == 2 && !sentUnchoke {
                try writeAll(cfd, frame(1))
                sentUnchoke = true
            } else if id == 6, msg.count >= 13 {
                let offset = be32(msg[5..<9])
                let length = be32(msg[9..<13])
                offsets?.values.append(offset)
                guard offset >= 0, length > 0, offset + length <= payload.count else { continue }
                var body = Data()
                appendBE32(&body, be32(msg[1..<5]))
                appendBE32(&body, offset)
                body.append(payload[offset..<(offset + length)])
                try writeAll(cfd, frame(7, body))
            }
        }
    }

    private static func readUntilHeader(_ fd: Int32) throws -> Data {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        while out.range(of: Data("\r\n\r\n".utf8)) == nil {
            var tmp = [UInt8](repeating: 0, count: 1024)
            let n = Darwin.read(fd, &tmp, tmp.count)
            if n <= 0 { throw POSIXError(.ETIMEDOUT) }
            out.append(tmp, count: n)
            if out.count > 16_384 { break }
        }
        return out
    }

    private static func frame(_ id: UInt8, _ payload: Data = Data()) -> Data {
        var body = Data([id])
        body.append(payload)
        var out = Data()
        appendBE32(&out, body.count)
        out.append(body)
        return out
    }

    private static func be32(_ bytes: Data.SubSequence) -> Int {
        let a = Array(bytes)
        guard a.count == 4 else { return 0 }
        return Int(a[0]) << 24 | Int(a[1]) << 16 | Int(a[2]) << 8 | Int(a[3])
    }
}

@MainActor
final class MagnetTests: XCTestCase {
    override func setUp() { NetworkPolicy.shared.allowLocalTrackers = true } // Tests nutzen 127.0.0.1-Tracker
    func testMagnetParsesHexAndBase32() {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        let m = MagnetLink("magnet:?xt=urn:btih:\(hex)&dn=Name&tr=http%3A%2F%2Fa.example%2Fannounce&tr=udp%3A%2F%2Fb.example%3A80")
        XCTAssertEqual(m?.infoHashHex, hex)
        XCTAssertEqual(m?.name, "Name")
        XCTAssertEqual(m?.trackers.count, 2)
        // Base32 desselben Hashes
        let b32 = "AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH"
        XCTAssertEqual(MagnetLink("magnet:?xt=urn:btih:\(b32)")?.infoHashHex, hex)
        XCTAssertNil(MagnetLink("magnet:?xt=urn:btih:zz"))
        XCTAssertNil(MagnetLink("http://example.com"))
    }

    /// Fake-Peer liefert ein info-Dict (2 Metadaten-Stücke) per ut_metadata; der Tracker nennt ihn.
    func testResolverFetchesMetadataFromPeer() async throws {
        let info: [String: Any] = [
            "length": 900 * 16_384, "name": "magnet.bin", "piece length": 16_384,
            "pieces": Data((0..<18_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }),
        ]
        let raw = try BB.encode(info)
        XCTAssertGreaterThan(raw.count, 16_384)
        let hash = Data(Insecure.SHA1.hash(data: raw))

        let (trackerFD, trackerPort) = try Loopback.bind()
        let (peerFD, peerPort) = try Loopback.bind()
        defer { Darwin.close(trackerFD); Darwin.close(peerFD) }
        let peers = Data([127, 0, 0, 1, UInt8(peerPort >> 8), UInt8(peerPort & 0xFF)])
        let body = try BB.encode(["interval": 60, "peers": peers] as [String: Any])
        let http = Task.detached { try? Loopback.serveHTTP(trackerFD, captured: RequestBox(), body: body) }
        let peer = Task.detached { try? Self.serveMetadata(peerFD, hash: hash, raw: raw) }
        defer { http.cancel(); peer.cancel() }

        let link = try XCTUnwrap(MagnetLink("magnet:?xt=urn:btih:\(hash.hex)&tr=http://127.0.0.1:\(trackerPort)/announce"))
        let data = try await MagnetResolver(link: link, extraTrackers: []).resolve(timeout: 10)
        let t = try TorrentParser.parse(data)
        XCTAssertEqual(t.infoHash, hash)
        XCTAssertEqual(t.name, "magnet.bin")
        XCTAssertEqual(t.numberOfPieces, 900)
    }

    nonisolated private static func serveMetadata(_ fd: Int32, hash: Data, raw: Data) throws {
        let cfd = try Loopback.accept(fd, timeout: 8)
        defer { Darwin.close(cfd) }
        _ = try Loopback.readExactly(cfd, 68, timeout: 5)
        try Loopback.writeAll(cfd, Loopback.handshake(infoHash: hash, peerID: Data(repeating: 9, count: 20)))
        func send(_ payload: Data) throws {
            var f = Data(); var n = payload.count
            for s in [24, 16, 8, 0] { f.append(UInt8((n >> s) & 0xFF)) }; n = 0
            try Loopback.writeAll(cfd, f + payload)
        }
        func readFrame() throws -> Data {
            let h = try Loopback.readExactly(cfd, 4, timeout: 5)
            let len = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            return len == 0 ? Data() : try Loopback.readExactly(cfd, len, timeout: 5)
        }
        let hello = try BB.encode(["m": ["ut_metadata": 3], "metadata_size": raw.count] as [String: Any])
        try send(Data([20, 0]) + hello)
        var served = 0
        let pieces = (raw.count + 16_383) / 16_384
        while served < pieces {
            let f = try readFrame()
            guard f.count > 2, f[0] == 20, f[1] == 3,
                  let d = try BB.decodeTolerant(Data(f.dropFirst(2))) as? [String: Any],
                  let idx = BB.int(d["piece"]) else { continue }
            let chunk = raw.subdata(in: idx * 16_384 ..< min(raw.count, (idx + 1) * 16_384))
            let head = try BB.encode(["msg_type": 1, "piece": idx, "total_size": raw.count] as [String: Any])
            try send(Data([20, 1]) + head + chunk)
            served += 1
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    func testFinishedDownloadMovesOutOfIncompleteFolder() async throws {
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 5) })
        let info: [String: Any] = [
            "length": payload.count, "name": "m.bin", "piece length": 32_768,
            "pieces": Data(Insecure.SHA1.hash(data: payload)),
        ]
        let torrent = try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)")
        let work = base.appendingPathComponent("unfertig/m"), final = base.appendingPathComponent("fertig/m")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try payload.write(to: work.appendingPathComponent("m.bin"))

        let engine = TorrentEngine(torrent: torrent, rootURL: work)
        engine.allowPublicTrackers = false
        engine.completedDir = final
        let moved = expectation(description: "moved")
        engine.onRelocated = { _ in moved.fulfill() }
        await engine.start()
        defer { engine.stop() }
        await fulfillment(of: [moved], timeout: 5)
        XCTAssertEqual(engine.rootURL, final)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("m.bin")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }
}

final class UDPTrackerTests: XCTestCase {
    override func setUp() { NetworkPolicy.shared.allowLocalTrackers = true } // Tests nutzen 127.0.0.1-Tracker
    /// Fake-UDP-Tracker nach BEP 15: connect → announce → ein Peer.
    func testUDPAnnounceReturnsPeers() async throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let server = Task.detached { () -> Int in
            func recv() -> (Data, sockaddr_storage, socklen_t)? {
                var buf = [UInt8](repeating: 0, count: 512)
                var from = sockaddr_storage(); var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fl) } }
                return n > 0 ? (Data(buf.prefix(n)), from, fl) : nil
            }
            func reply(_ d: Data, _ from: sockaddr_storage, _ fl: socklen_t) {
                var f = from
                _ = d.withUnsafeBytes { b in withUnsafePointer(to: &f) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, d.count, 0, $0, fl) } } }
            }
            guard let (c, from, fl) = recv(), c.count == 16 else { return 0 }
            reply(Data([0, 0, 0, 0]) + c[12..<16] + Data([0, 0, 0, 0, 0, 0, 0, 42]), from, fl) // action 0, tx, connection_id
            guard let (a, from2, fl2) = recv(), a.count == 98, a[8..<12] == Data([0, 0, 0, 1]) else { return 0 }
            let peers = Data([10, 1, 2, 3, 0x1A, 0xE1])
            reply(Data([0, 0, 0, 1]) + a[12..<16] + Data([0, 0, 0x07, 0x08, 0, 0, 0, 1, 0, 0, 0, 2]) + peers, from2, fl2)
            return 1
        }
        let res = try await TrackerClient.announce(
            url: URL(string: "udp://127.0.0.1:\(port)/announce")!, infoHash: Data(repeating: 1, count: 20),
            peerID: Data(repeating: 2, count: 20), port: 6881, uploaded: 0, downloaded: 0, left: 100, event: "started")
        let served = await server.value
        XCTAssertEqual(served, 1)
        XCTAssertEqual(res.peers, [PeerAddress(ip: "10.1.2.3", port: 6881)])
        XCTAssertEqual(res.interval, 1800)
    }
}

final class DHTTests: XCTestCase {
    /// Fake-DHT-Knoten: antwortet auf find_node/get_peers/announce_peer. Prüft Bootstrap, Knotenzahl, Lookup und Announce.
    func testBootstrapLookupAndAnnounce() async throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let fakeID = Data(repeating: 0xAB, count: 20)
        let announced = OffsetBox()
        let stop = OffsetBox()
        let server = Task.detached {
            while stop.values.isEmpty {
                var buf = [UInt8](repeating: 0, count: 2048)
                var from = sockaddr_storage(); var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fl) } }
                guard n > 0, let d = (try? BB.decodeTolerant(Data(buf.prefix(n)))) as? [String: Any],
                      let t = BB.data(d["t"]), let q = BB.string(d["q"]), let a = d["a"] as? [String: Any] else { continue }
                XCTAssertEqual(BB.int(d["ro"]), 1)
                var r: [String: Any] = ["id": fakeID]
                switch q {
                case "get_peers":
                    r["token"] = Data("tk".utf8)
                    r["values"] = [Data([10, 1, 2, 3, 0x1A, 0xE1])]
                case "find_node":
                    r["nodes"] = Data()
                case "announce_peer":
                    XCTAssertEqual(BB.data(a["token"]), Data("tk".utf8))
                    announced.values.append(BB.int(a["port"]) ?? -1)
                default: break
                }
                guard let out = try? BB.encode(["t": t, "y": "r", "r": r] as [String: Any]) else { continue }
                _ = out.withUnsafeBytes { b in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, out.count, 0, $0, fl) } } }
            }
        }
        defer { stop.values.append(1); server.cancel() }

        let dht = DHT(routers: [("127.0.0.1", port)])
        dht.start()
        defer { dht.stop() }
        let deadline = Date().addingTimeInterval(6)
        while dht.nodeCount < 1 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(dht.nodeCount, 1)

        let found = OffsetBox()  // Port des gefundenen Peers
        await dht.lookup(infoHash: Data(repeating: 7, count: 20), announcePort: 7000) { peers in
            for p in peers where p.ip == "10.1.2.3" { found.values.append(p.port) }
        }
        XCTAssertEqual(found.values, [6881])
        let d2 = Date().addingTimeInterval(3)
        while announced.values.isEmpty && Date() < d2 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(announced.values, [7000])
    }

    /// Echtes Netz, nur mit TEST_RUNNER_MT_LIVE=1: bootstrapt gegen die öffentlichen Router und sucht Peers für Ubuntu.
    func testLiveBootstrapAndLookup() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MT_LIVE"] == "1", "nur mit MT_LIVE=1")
        // MT_IFACE=en0 (oder utun…) prüft die Schnittstellenbindung im echten Netz
        let iface = ProcessInfo.processInfo.environment["MT_IFACE"].flatMap { $0.isEmpty ? nil : $0 }
        NetworkPolicy.shared.interfaceName = iface
        defer { NetworkPolicy.shared.interfaceName = nil }
        let dht = DHT()
        dht.start()
        defer { dht.stop() }
        let deadline = Date().addingTimeInterval(40)
        var n = 0
        while dht.nodeCount < 50 && Date() < deadline { try await Task.sleep(nanoseconds: 500_000_000); n += 1; if n % 6 == 0 { print("LIVE t=\(n/2)s nodes=\(dht.nodeCount)") } }
        print("LIVE DHT nodes:", dht.nodeCount)
        XCTAssertGreaterThanOrEqual(dht.nodeCount, 50)
        // Bekannte, gut besuchte Test-Torrents (Big Buck Bunny, Sintel, Tears of Steel)
        var total = 0
        for h in ["dd8255ecdc7ca55fb0bbf81323d87062db2f4e87", "08ada5a7a6183aae1e09d831df6748d566095a10",
                  "209c8226b299b308beaf2b9cd3fb49212dbd13ec"] {
            let found = OffsetBox()
            await dht.lookup(infoHash: MagnetLink("magnet:?xt=urn:btih:\(h)")!.infoHash) { found.values.append($0.count) }
            print("LIVE DHT peers \(h.prefix(8)):", found.values.reduce(0, +))
            total += found.values.reduce(0, +)
        }
        print("LIVE DHT total peers:", total)
        XCTAssertGreaterThan(total, 0)
    }
}

@MainActor
final class PrivacyTests: XCTestCase {
    override func setUp() { NetworkPolicy.shared.allowLocalTrackers = true } // Tests nutzen 127.0.0.1-Tracker
    override func tearDown() {
        NetworkPolicy.shared.allowLocalTrackers = false
        NetworkPolicy.shared.interfaceName = nil
        NetworkPolicy.shared.anonymous = false
    }

    /// Kill-Switch: ist die erzwungene Schnittstelle nicht da, darf nichts gesendet werden.
    func testBlockedInterfaceStopsEverything() async throws {
        NetworkPolicy.shared.interfaceName = "nonexistent99"
        XCTAssertTrue(NetworkPolicy.shared.isBlocked)

        let info: [String: Any] = ["length": 10, "name": "x.bin", "piece length": 16_384, "pieces": Data(repeating: 1, count: 20)]
        let t = try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentEngine(torrent: t, rootURL: root)
        await engine.start()
        XCTAssertFalse(engine.isRunning)
        if case .failed = engine.state {} else { XCTFail("Engine hätte nicht starten dürfen: \(engine.state)") }

        do { _ = try await HTTPClient.get(URL(string: "http://127.0.0.1:1/")!); XCTFail("HTTP trotz Sperre") } catch {}
        do {
            _ = try await TrackerClient.announce(url: URL(string: "udp://127.0.0.1:1/a")!, infoHash: Data(count: 20),
                peerID: Data(count: 20), port: 1, uploaded: 0, downloaded: 0, left: 1, event: nil)
            XCTFail("UDP trotz Sperre")
        } catch {}
    }

    /// Anonymer Modus: Peer-ID ohne Client-Kürzel, kein Listener.
    func testAnonymousModeHidesClientAndPort() async throws {
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let info: [String: Any] = ["length": payload.count, "name": "a.bin", "piece length": 32_768,
                                   "pieces": Data(Insecure.SHA1.hash(data: payload))]
        let t = try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try payload.write(to: root.appendingPathComponent("a.bin"))

        NetworkPolicy.shared.anonymous = true
        XCTAssertFalse(TorrentEngine.makePeerID().starts(with: Data("-MT".utf8)))
        let engine = TorrentEngine(torrent: t, rootURL: root)
        engine.allowPublicTrackers = false
        await engine.start()
        defer { engine.stop() }
        XCTAssertEqual(engine.state, .done)
        XCTAssertEqual(engine.listenPort, 0, "Anonymer Modus darf keinen Port öffnen")

        NetworkPolicy.shared.anonymous = false
        XCTAssertTrue(TorrentEngine.makePeerID().starts(with: Data("-MT0001-".utf8)))
    }

    /// Eigener HTTP-Client: Redirect, Chunked-Antwort, kein User-Agent.
    func testHTTPClientFollowsRedirectAndDecodesChunks() async throws {
        let (fd, port) = try Loopback.bind()
        defer { Darwin.close(fd) }
        let seen = RequestBox()
        let server = Task.detached {
            for n in 0..<2 {
                let c = try Loopback.accept(fd, timeout: 5)
                let req = String(decoding: try Loopback.readSome(c, timeout: 3), as: UTF8.self)
                if n == 1 { seen.line = req }
                let resp = n == 0
                    ? "HTTP/1.1 302 Found\r\nLocation: /b?x=1\r\nContent-Length: 0\r\n\r\n"
                    : "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
                try Loopback.writeAll(c, Data(resp.utf8))
                Darwin.close(c)
            }
        }
        let body = try await HTTPClient.get(URL(string: "http://127.0.0.1:\(port)/a")!)
        try await server.value
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")
        XCTAssertTrue(seen.line.hasPrefix("GET /b?x=1 HTTP/1.0"), seen.line)
        XCTAssertFalse(seen.line.lowercased().contains("user-agent"), seen.line)
    }
}

@MainActor
final class SharedPortTests: XCTestCase {
    private func makeSeed(_ seedByte: UInt8, name: String) throws -> (TorrentInfo, Data, URL) {
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* Int(seedByte)) })
        let info: [String: Any] = ["length": payload.count, "name": name, "piece length": 32_768,
                                   "pieces": Data(Insecure.SHA1.hash(data: payload))]
        let t = try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: root.appendingPathComponent(name))
        return (t, payload, root)
    }

    private func firstBlock(port: Int, torrent: TorrentInfo) async throws -> Data? {
        let client = PeerConnection(infoHash: torrent.infoHash, peerID: Data(repeating: 5, count: 20))
        let events = client.makeStream()
        client.start(host: "127.0.0.1", port: port)
        let got = OffsetBox2()
        let reader = Task {
            for try await e in events {
                switch e {
                case .handshake: try client.send(PeerConnection.frame(2))
                case .message(let d):
                    switch PeerMessage.parse(d) {
                    case .unchoke:
                        var req = Data(); appendBE32(&req, 0); appendBE32(&req, 0); appendBE32(&req, 16_384)
                        try client.send(PeerConnection.frame(6, req))
                    case .piece(_, _, let block): got.data = block; return
                    default: break
                    }
                }
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while got.data == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        reader.cancel(); client.close()
        return got.data
    }

    /// Zwei Torrents, ein gewünschter Port: der Listener ordnet Verbindungen per Info-Hash zu.
    func testTwoTorrentsShareOneManualPort() async throws {
        let (fd, port) = try Loopback.bind()
        Darwin.close(fd) // Port frei geben, Engine soll ihn belegen
        let (tA, pA, rA) = try makeSeed(3, name: "a.bin")
        let (tB, pB, rB) = try makeSeed(5, name: "b.bin")
        defer { try? FileManager.default.removeItem(at: rA); try? FileManager.default.removeItem(at: rB) }
        let a = TorrentEngine(torrent: tA, rootURL: rA), b = TorrentEngine(torrent: tB, rootURL: rB)
        for e in [a, b] { e.allowPublicTrackers = false; e.preferredPort = Int(port) }
        await a.start(); await b.start()
        defer { a.stop(); b.stop() }
        XCTAssertEqual(a.listenPort, Int(port))
        XCTAssertEqual(b.listenPort, Int(port))

        let blockA = try await firstBlock(port: Int(port), torrent: tA)
        let blockB = try await firstBlock(port: Int(port), torrent: tB)
        XCTAssertEqual(blockA, pA.prefix(16_384))
        XCTAssertEqual(blockB, pB.prefix(16_384))
        XCTAssertNotEqual(blockA, blockB)

        // Stoppt der letzte Torrent, wird der Port wieder frei.
        a.stop(); b.stop()
        let gone = Date().addingTimeInterval(3) // stop() arbeitet jetzt im Hintergrund
        while PeerListener.shared.port != 0 && Date() < gone { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(PeerListener.shared.port, 0)
    }

    /// Ist der gewünschte Port belegt, meldet die Engine das, statt still einen anderen zu nehmen.
    func testBusyManualPortIsReportedNotSilentlyChanged() async throws {
        let (fd, port) = try Loopback.bind() // bleibt offen = belegt
        defer { Darwin.close(fd) }
        let (t, _, r) = try makeSeed(7, name: "c.bin")
        defer { try? FileManager.default.removeItem(at: r) }
        let e = TorrentEngine(torrent: t, rootURL: r)
        e.allowPublicTrackers = false
        e.preferredPort = Int(port)
        await e.start()
        defer { e.stop() }
        XCTAssertEqual(e.listenPort, 0)
        XCTAssertTrue(e.logs.contains { $0.contains("belegt") }, e.logs.joined(separator: "\n"))
    }
}

private final class OffsetBox2: @unchecked Sendable { var data: Data? }

final class PathSafetyTests: XCTestCase {
    private func torrent(_ info: [String: Any]) throws -> TorrentInfo {
        var i = info
        i["piece length"] = 16_384
        i["pieces"] = Data(repeating: 1, count: 20)
        return try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": i] as [String: Any]))
    }

    /// Pfadteile wie „..“ oder mit „/“ dürfen nie zu Dateien außerhalb des Download-Ordners führen.
    func testTraversalInFilePathIsRejected() throws {
        for bad in [["..", "evil"], ["a", "..", "..", "x"], ["", "x"], ["a/b"], ["."], ["x\u{0}y"], []] as [[String]] {
            let info: [String: Any] = ["name": "t", "files": [["length": 1, "path": bad]]]
            XCTAssertThrowsError(try torrent(info), "\(bad) hätte abgelehnt werden müssen")
        }
        let ok = try torrent(["name": "t", "files": [["length": 1, "path": ["sub", "file.txt"]]]])
        XCTAssertEqual(ok.entries.first?.path, "sub/file.txt")
        XCTAssertEqual(ok.name, "t") // Mehrdatei-Torrents behalten ihren Namen
    }

    /// Der Torrent-Name wird Ordner- bzw. Dateiname: nie „.“/„..“, nie mit Pfadtrenner.
    func testDangerousNamesAreSanitized() throws {
        for (raw, safe) in [("..", "torrent"), (".", "torrent"), ("", "torrent"), ("../../etc/passwd", "–..–etc–passwd"), ("a\\b", "a–b")] {
            let t = try torrent(["name": raw, "length": 10])
            XCTAssertEqual(t.name, safe)
            XCTAssertEqual(t.entries.first?.path, safe)
            XCTAssertFalse(t.entries[0].path.contains("/"))
        }
    }

    /// Zweite Sicherung: selbst ein von Hand gebauter Eintrag mit „..“ scheitert beim Anlegen der Dateien.
    func testPieceStoreRefusesEscapingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)/inner")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let t = TorrentInfo(name: "x", infoHash: Data(count: 20), infoHashHex: "", pieceLength: 16_384,
                            pieceHashes: [Data(count: 20)],
                            entries: [TorrentEntry(path: "../escaped.txt", pieceOffset: 0, length: 1)],
                            totalSize: 1, trackerURLs: [], created: nil)
        XCTAssertThrowsError(try PieceStore(torrent: t, rootURL: root).prepareFiles())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }
}

final class LocalTrackerFilterTests: XCTestCase {
    func testLocalHostDetection() {
        for h in ["localhost", "127.0.0.1", "10.0.0.5", "192.168.1.1", "172.16.0.1", "172.31.255.1", "169.254.1.1", "printer.local", "[::1]", "fe80::1", "0.0.0.0"] {
            XCTAssertTrue(NetworkPolicy.isLocalHost(h), h)
        }
        for h in ["tracker.opentrackr.org", "8.8.8.8", "172.32.0.1", "172.15.0.1", "193.168.1.1", "1.2.3.4", nil] as [String?] {
            XCTAssertFalse(NetworkPolicy.isLocalHost(h), h ?? "nil")
        }
    }

    /// Ein fremder Torrent darf per Tracker-URL keine Anfragen an Router/LAN-Geräte schicken.
    func testAnnounceToLocalTrackerIsBlockedByDefault() async {
        NetworkPolicy.shared.allowLocalTrackers = false
        for u in ["http://192.168.1.1/admin/reboot", "http://127.0.0.1:8080/a", "udp://10.0.0.1:6969/announce"] {
            do {
                _ = try await TrackerClient.announce(url: URL(string: u)!, infoHash: Data(count: 20), peerID: Data(count: 20),
                                                     port: 1, uploaded: 0, downloaded: 0, left: 1, event: nil)
                XCTFail("\(u) hätte blockiert werden müssen")
            } catch let e as HTTPClient.HTTPError { XCTAssertTrue(e.message.contains("blockiert"), e.message) }
            catch { XCTFail("falscher Fehler für \(u): \(error)") }
        }
    }

    func testDotNamesLoseLeadingDots() {
        XCTAssertEqual(TorrentParser.sanitizedName(".ssh"), "ssh")
        XCTAssertEqual(TorrentParser.sanitizedName("...."), "torrent")
        XCTAssertEqual(TorrentParser.sanitizedName("Library"), "Library")
    }
}

/// Opt-in Ende-zu-Ende-Test im echten Netz (TEST_RUNNER_MT_LIVE=1): Magnet (Sintel) → Metadaten per DHT/Tracker → Download.
@MainActor
final class LiveEndToEndTests: XCTestCase {
    func testMagnetToDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MT_LIVE"] == "1", "nur mit MT_LIVE=1")
        NetworkPolicy.shared.anonymous = false
        let dht = DHT()
        dht.start()
        defer { dht.stop() }
        let link = try XCTUnwrap(MagnetLink("magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"))
        let t0 = Date()
        let data = try await MagnetResolver(link: link, dht: dht).resolve(timeout: 90)
        print("LIVE metadata in", String(format: "%.1f", Date().timeIntervalSince(t0)), "s, bytes:", data.count)
        let torrent = try TorrentParser.parse(data)
        print("LIVE torrent:", torrent.name, "pieces:", torrent.numberOfPieces, "size MB:", torrent.totalSize / 1_000_000, "files:", torrent.numberOfFiles)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mt-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentEngine(torrent: torrent, rootURL: root)
        engine.dht = dht
        await engine.start()
        defer { engine.stop() }
        let start = Date()
        var peak: Int64 = 0
        var lastPrint = Date()
        while Date().timeIntervalSince(start) < 60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            peak = max(peak, engine.progress.downSpeed)
            if Date().timeIntervalSince(lastPrint) > 5 {
                lastPrint = Date()
                let p = engine.progress
                let open = engine.peerList.filter { !$0.theyChokeUs }.count
                let withPieces = engine.peerList.filter { $0.progress > 0 }.count
                let delivering = engine.peerList.filter { $0.downRate > 0 }.count
                print("LIVE t=\(Int(Date().timeIntervalSince(start)))s peers=\(p.peers) unchoked=\(open) withPieces=\(withPieces) delivering=\(delivering) pieces=\(p.downloadedPieces) down=\(p.downSpeed / 1000)kB/s")
            }
            if engine.progress.verifiedBytes > 80_000_000 { break }
        }
        let p = engine.progress
        print("LIVE final: verified MB", p.verifiedBytes / 1_000_000, "peak kB/s", peak / 1000, "peers", p.peers)
        print("LIVE log tail:\n" + engine.logs.suffix(12).joined(separator: "\n"))
        XCTAssertGreaterThan(p.verifiedBytes, 0, "nach 60 s kein einziges Piece")
    }
}

final class PortMapperTests: XCTestCase {
    private func bindUDP() -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var l = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &l) } }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return (fd, UInt16(bigEndian: a.sin_port))
    }

    /// Fake-UDP-Server: ruft `reply` für jedes Datagramm auf und schickt dessen Antwort zurück.
    private func serveUDP(_ fd: Int32, _ stop: OffsetBox, _ reply: @escaping @Sendable (Data) -> Data?) -> Task<Void, Never> {
        Task.detached {
            while stop.values.isEmpty {
                var buf = [UInt8](repeating: 0, count: 2048)
                var from = sockaddr_storage(); var fl = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fl) } }
                guard n > 0, let out = reply(Data(buf.prefix(n))) else { continue }
                _ = out.withUnsafeBytes { b in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, out.count, 0, $0, fl) } } }
            }
        }
    }

    func testNATPMPMapsPortAndReportsExternalIP() async throws {
        let (fd, port) = bindUDP()
        defer { Darwin.close(fd) }
        let stop = OffsetBox()
        let server = serveUDP(fd, stop) { req in
            if req == Data([0, 0]) { return Data([0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 5]) }
            guard req.count == 12, req[1] == 2 else { return nil }
            // Antwort: Version, Op 130, OK, Epoch, interner Port, externer Port (= angefragt), Lebensdauer
            return Data([0, 130, 0, 0, 0, 0, 0, 1]) + req[4..<6] + req[6..<8] + req[8..<12]
        }
        defer { stop.values.append(1); server.cancel() }
        let mapper = PortMapper(config: .init(gateway: "127.0.0.1", natPMPPort: port, ssdpPort: 1, timeout: 0.5))
        let m = await mapper.map(port: 51413)
        XCTAssertEqual(m, PortMapper.Mapping(method: "NAT-PMP", port: 51413, externalIP: "203.0.113.5"))
        await mapper.unmap()
        let after = await mapper.mapping
        XCTAssertNil(after)
    }

    func testUPnPFallbackAddsMapping() async throws {
        let (ssdpFD, ssdpPort) = bindUDP()
        defer { Darwin.close(ssdpFD) }
        let (httpFD, httpPort) = try Loopback.bind()
        defer { Darwin.close(httpFD) }
        let stop = OffsetBox()
        let ssdp = serveUDP(ssdpFD, stop) { req in
            guard String(decoding: req, as: UTF8.self).hasPrefix("M-SEARCH") else { return nil }
            return Data("HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:\(httpPort)/desc.xml\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n".utf8)
        }
        let added = RequestBox()
        let http = Task.detached {
            for _ in 0..<5 {
                guard let c = try? Loopback.accept(httpFD, timeout: 3) else { return }
                var data = Data()
                while !data.contains(Data("\r\n\r\n".utf8)) || !Self.complete(data) {
                    guard let chunk = try? Loopback.readSome(c, timeout: 1) else { break }
                    data.append(chunk)
                }
                let req = String(decoding: data, as: UTF8.self)
                var body = "<ok/>"
                if req.hasPrefix("GET /desc.xml") {
                    body = "<root><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl</controlURL></service></serviceList></device></root>"
                } else if req.contains("#AddPortMapping") {
                    added.line = req
                } else if req.contains("#GetExternalIPAddress") {
                    body = "<r><NewExternalIPAddress>198.51.100.7</NewExternalIPAddress></r>"
                }
                try? Loopback.writeAll(c, Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
                Darwin.close(c)
            }
        }
        defer { stop.values.append(1); ssdp.cancel(); http.cancel() }
        // NAT-PMP-Port ohne Server: läuft in den Timeout, danach greift UPnP
        let mapper = PortMapper(config: .init(gateway: "127.0.0.1", natPMPPort: 9, ssdpPort: ssdpPort, timeout: 0.4))
        let m = await mapper.map(port: 51413)
        XCTAssertEqual(m, PortMapper.Mapping(method: "UPnP", port: 51413, externalIP: "198.51.100.7"))
        XCTAssertTrue(added.line.contains("<NewExternalPort>51413</NewExternalPort>"), added.line)
        XCTAssertTrue(added.line.contains("<NewInternalClient>127.0.0.1</NewInternalClient>"), added.line)
        XCTAssertTrue(added.line.contains("<NewProtocol>TCP</NewProtocol>"))
    }

    /// Header vollständig und (falls Content-Length) Body da?
    nonisolated private static func complete(_ d: Data) -> Bool {
        let s = String(decoding: d, as: UTF8.self)
        guard let r = s.range(of: "\r\n\r\n") else { return false }
        let head = s[..<r.lowerBound].lowercased()
        guard let cl = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") })
            .flatMap({ Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) }) else { return true }
        return s[r.upperBound...].utf8.count >= cl
    }

    func testDescriptionParserFindsWANService() throws {
        let xml = """
        <root><device><deviceList><device><deviceList><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/common</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/ppp</controlURL></service>
        </serviceList></device></deviceList></device></deviceList></device></root>
        """
        let r = try XCTUnwrap(PortMapper.parseService(Data(xml.utf8)))
        XCTAssertEqual(r.0, "/ppp")
        XCTAssertTrue(r.1.contains("WANPPPConnection"))
        XCTAssertNil(PortMapper.parseService(Data("<root/>".utf8)))
    }
}

final class LivePortMapperTests: XCTestCase {
    /// Opt-in (MT_LIVE=1): fragt den echten Router per NAT-PMP/UPnP und entfernt den Eintrag sofort wieder.
    func testRealRouter() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MT_LIVE"] == "1", "nur mit MT_LIVE=1")
        print("LIVE gateway:", NetworkPolicy.shared.gatewayIPv4 ?? "keins")
        let m = PortMapper()
        let r = await m.map(port: 51999)
        print("LIVE mapping:", String(describing: r))
        await m.unmap()
    }
}

@MainActor
final class SelectionAndChokingTests: XCTestCase {
    /// Zwei Dateien à 20000 Byte, Piece 16384: Datei A = Pieces 0–1, Datei B = Pieces 1–2.
    func testWantedPiecesFollowFileSelection() throws {
        let info: [String: Any] = [
            "name": "multi", "piece length": 16_384,
            "pieces": Data(repeating: 1, count: 60),
            "files": [["length": 20_000, "path": ["a.bin"]], ["length": 20_000, "path": ["b.bin"]]],
        ]
        let t = try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]))
        let store = PieceStore(torrent: t, rootURL: FileManager.default.temporaryDirectory)
        XCTAssertEqual(store.wantedPieceCount, 3)
        store.setWanted(files: [true, false])
        XCTAssertEqual(store.wantedPieceCount, 2)
        XCTAssertTrue(store.isWanted(0)); XCTAssertTrue(store.isWanted(1)); XCTAssertFalse(store.isWanted(2))
        XCTAssertEqual(store.wantedBytes, 16_384 + 16_384) // Piece 0 + Piece 1 (20000 − 16384 = 3616 … ganzes Piece 1 ist kürzer)
        XCTAssertFalse(store.isComplete)
        store.setValid(0, true); store.setValid(1, true)
        XCTAssertTrue(store.isComplete) // Piece 2 wird nicht gebraucht
        store.setWanted(files: [true, true])
        XCTAssertFalse(store.isComplete)
        store.setValid(2, true)
        XCTAssertTrue(store.isComplete)
    }

    /// Tit-for-Tat: sofort entsperrt werden höchstens 5 interessierte Peers (4 reguläre + 1 optimistischer).
    func testUnchokeSlotsAreLimited() async throws {
        let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })
        let info: [String: Any] = ["length": payload.count, "name": "s.bin", "piece length": 32_768,
                                   "pieces": Data(Insecure.SHA1.hash(data: payload))]
        let t = try TorrentParser.parse(try BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try payload.write(to: root.appendingPathComponent("s.bin"))
        NetworkPolicy.shared.allowLocalTrackers = true
        let engine = TorrentEngine(torrent: t, rootURL: root)
        engine.allowPublicTrackers = false
        await engine.start()
        defer { engine.stop() }
        XCTAssertNotEqual(engine.listenPort, 0)

        let unchokes = OffsetBox()
        var clients: [PeerConnection] = []
        var readers: [Task<Void, Never>] = []
        for i in 0..<8 {
            let c = PeerConnection(infoHash: t.infoHash, peerID: Data(repeating: UInt8(10 + i), count: 20))
            let ev = c.makeStream()
            c.start(host: "127.0.0.1", port: engine.listenPort)
            clients.append(c)
            readers.append(Task {
                do {
                    for try await e in ev {
                        switch e {
                        case .handshake: try c.send(PeerConnection.frame(2))
                        case .message(let d): if case .unchoke = PeerMessage.parse(d) { unchokes.values.append(i) }
                        }
                    }
                } catch {}
            })
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        readers.forEach { $0.cancel() }; clients.forEach { $0.close() }
        XCTAssertEqual(unchokes.values.count, 5, "unchoked: \(unchokes.values)")
        // Die Peer-Liste der Oberfläche zeigt dieselben Verbindungen samt Freigabe-Status.
        let listed = engine.peerList.filter(\.weUnchoke).count
        XCTAssertLessThanOrEqual(listed, 5)
    }
}
