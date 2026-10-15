import Foundation
import Network

/// Mainline-DHT (BEP 5) als reiner Client: findet Peers ohne Tracker und macht uns über
/// `announce_peer` auffindbar. Wir senden `ro=1` (BEP 43), beantworten also keine Anfragen
/// und brauchen keinen festen UDP-Port. ponytail: flache Knotenliste statt k-Buckets,
/// IPv4 only; bei Bedarf Buckets + eingehende Anfragen nachrüsten.
public final class DHT: @unchecked Sendable {
    public static let defaultRouters: [(String, UInt16)] = [
        ("router.bittorrent.com", 6881), ("dht.transmissionbt.com", 6881), ("router.utorrent.com", 6881),
    ]

    private struct Node {
        let id: Data
        let ip: String
        let port: UInt16
        var good = false            // hat mindestens einmal geantwortet
        var failures = 0
        var lastQuery = Date.distantPast
    }

    private struct Pending {
        let ip: String
        let port: UInt16
        let nodeID: Data?
        let deadline: Date
        let done: ([String: Any]?) -> Void
    }

    private let q = DispatchQueue(label: "ch.stefan.mactorrent.dht")
    private let routers: [(String, UInt16)]
    private let storage: URL?
    private var myID: Data
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var nodes: [Data: Node] = [:]
    private var routerAddrs: [(String, UInt16)] = []
    private var pending: [UInt16: Pending] = [:]
    private var tx = UInt16.random(in: 0...UInt16.max)
    private var ticks = 0
    private var running = false
    private static let maxNodes = 3000

    public init(routers: [(String, UInt16)] = DHT.defaultRouters, storage: URL? = nil) {
        self.routers = routers
        self.storage = storage
        self.myID = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
    }

    /// Verifizierte Knoten (haben geantwortet) – die Zahl, die die UI zeigt.
    public var nodeCount: Int { q.sync { nodes.values.filter(\.good).count } }
    public var isRunning: Bool { q.sync { running } }

    // MARK: - Lifecycle

    public func start() {
        q.async { [self] in
            guard !running else { return }
            guard openSocket() else { return }
            running = true
            load()
            bootstrap()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        q.sync {
            guard running else { return }
            save()
            running = false
            timer?.cancel(); timer = nil
            readSource?.cancel(); readSource = nil // Cancel-Handler schließt den Socket
            let all = pending
            pending = [:]
            all.values.forEach { $0.done(nil) }
        }
    }

    public func save() {
        q.async { [self] in saveNow() }
    }

    private func openSocket() -> Bool {
        guard !NetworkPolicy.shared.isBlocked else { return false } // VPN-Schutz
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return false }
        // Erzwungene Schnittstelle: Socket fest daran binden (IP_BOUND_IF), sonst gehen UDP-Pakete über die Standardroute.
        if let idx = NetworkPolicy.shared.interface?.index {
            var i = UInt32(idx)
            guard setsockopt(s, IPPROTO_IP, IP_BOUND_IF, &i, socklen_t(MemoryLayout<UInt32>.size)) == 0 else { Darwin.close(s); return false }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = 0
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { Darwin.close(s); return false }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        src.setEventHandler { [weak self] in self?.readAll() }
        src.setCancelHandler { Darwin.close(s) }
        src.resume()
        readSource = src
        return true
    }

    // MARK: - Senden / Empfangen

    private func sendRaw(_ data: Data, _ ip: String, _ port: UInt16) {
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr(ip)
        addr.sin_port = port.bigEndian
        _ = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func readAll() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n <= 0 { return }
            handle(Data(buf.prefix(n)), ip: String(cString: inet_ntoa(from.sin_addr)))
        }
    }

    private func query(_ ip: String, _ port: UInt16, _ name: String, _ args: [String: Any],
                       nodeID: Data? = nil, done: @escaping ([String: Any]?) -> Void) {
        tx &+= 1
        let t = tx
        var a = args
        a["id"] = myID
        let msg: [String: Any] = ["t": Data([UInt8(t >> 8), UInt8(t & 0xFF)]), "y": "q", "q": name, "a": a, "ro": 1]
        guard running, let data = try? BB.encode(msg) else { done(nil); return }
        pending[t] = Pending(ip: ip, port: port, nodeID: nodeID, deadline: Date().addingTimeInterval(4), done: done)
        if let nodeID { nodes[nodeID]?.lastQuery = Date() }
        sendRaw(data, ip, port)
    }

    private func handle(_ data: Data, ip: String) {
        guard let d = (try? BB.decodeTolerant(data)) as? [String: Any],
              let t = BB.data(d["t"]), t.count == 2 else { return }
        let b = Array(t)
        let key = UInt16(b[0]) << 8 | UInt16(b[1])
        guard let p = pending[key], p.ip == ip else { return }
        pending[key] = nil
        guard BB.string(d["y"]) == "r", let r = d["r"] as? [String: Any] else { p.done(nil); return }
        if let id = BB.data(r["id"]), id.count == 20 { markGood(id, ip, p.port) }
        p.done(r)
    }

    // MARK: - Knotenliste

    private func markGood(_ id: Data, _ ip: String, _ port: UInt16) {
        guard id != myID else { return }
        var n = nodes[id] ?? Node(id: id, ip: ip, port: port)
        n.good = true
        n.failures = 0
        nodes[id] = n
        trim()
    }

    /// Unverifizierter Kandidat aus einer `nodes`-Antwort.
    private func addCandidate(_ id: Data, _ ip: String, _ port: UInt16) {
        guard id != myID, port != 0, ip != "0.0.0.0", nodes[id] == nil else { return }
        nodes[id] = Node(id: id, ip: ip, port: port)
        trim()
    }

    private func fail(_ id: Data?) {
        guard let id, var n = nodes[id] else { return }
        n.failures += 1
        if n.failures >= (n.good ? 3 : 1) { nodes[id] = nil } else { nodes[id] = n }
    }

    private func trim() {
        guard nodes.count > Self.maxNodes else { return }
        // Erst unverifizierte, dann die am längsten nicht angefragten.
        let drop = nodes.values.sorted { ($0.good ? 1 : 0, $0.lastQuery) < ($1.good ? 1 : 0, $1.lastQuery) }.prefix(300)
        for n in drop { nodes[n.id] = nil }
    }

    private static func parseCompactNodes(_ blob: Data) -> [(Data, String, UInt16)] {
        let b = Array(blob)
        var out: [(Data, String, UInt16)] = []
        for i in stride(from: 0, to: b.count - 25, by: 26) {
            out.append((Data(b[i..<i + 20]), "\(b[i+20]).\(b[i+21]).\(b[i+22]).\(b[i+23])", UInt16(b[i+24]) << 8 | UInt16(b[i+25])))
        }
        return out
    }

    private static func parsePeers(_ values: [Any]) -> [PeerAddress] {
        values.compactMap { v in
            guard let d = v as? Data, d.count == 6 else { return nil }
            let b = Array(d)
            return PeerAddress(ip: "\(b[0]).\(b[1]).\(b[2]).\(b[3])", port: Int(b[4]) << 8 | Int(b[5]))
        }
    }

    private func closest(to target: Data, _ n: Int) -> [Node] {
        let t = Array(target)
        func dist(_ id: Data) -> [UInt8] { zip(id, t).map { $0 ^ $1 } }
        return Array(nodes.values.sorted { a, b in
            if a.good != b.good { return a.good }
            return dist(a.id).lexicographicallyPrecedes(dist(b.id))
        }.prefix(n))
    }

    // MARK: - Bootstrap + Pflege

    private func bootstrap() {
        let routers = self.routers
        // „Erzwungen“, nicht „gerade vorhanden“: fällt das VPN weg, darf der DNS-Lookup nicht auf die Standardroute ausweichen.
        let restricted = NetworkPolicy.shared.interfaceName != nil
        if NetworkPolicy.shared.isBlocked { return }
        DispatchQueue.global().async { [weak self] in
            var found: [(String, UInt16)] = []
            if restricted {
                // getaddrinfo kennt keine Schnittstelle (DNS-Leck): über Network.framework auflösen, das den Pfad einhält.
                // Alle parallel auflösen und auf alle warten (ein toter Router soll die anderen nicht aufhalten).
                let group = DispatchGroup(), lock = NSLock()
                func add(_ ip: String, _ port: UInt16) { lock.lock(); found.append((ip, port)); lock.unlock() }
                for (host, port) in routers {
                    group.enter()
                    Task {
                        if let ip = await Self.resolveViaNetwork(host: host, port: port) { add(ip, port) }
                        group.leave()
                    }
                }
                _ = group.wait(timeout: .now() + 8)
            }
            for (host, port) in routers where !restricted {
                var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { continue }
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let ai = p {
                    if let sa = ai.pointee.ai_addr {
                        let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
                        found.append((ip, port))
                    }
                    p = ai.pointee.ai_next
                }
                freeaddrinfo(first)
            }
            self?.q.async {
                guard let self, self.running else { return }
                self.routerAddrs = found
                self.findNode(at: found)
            }
        }
        // Gemerkte Knoten der letzten Sitzung gleich mit anfragen.
        findNode(at: nodes.values.prefix(40).map { ($0.ip, $0.port) })
    }

    /// Löst einen Hostnamen über eine UDP-NWConnection auf (hält die erzwungene Schnittstelle ein).
    private static func resolveViaNetwork(host: String, port: UInt16) async -> String? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let params = NetworkPolicy.shared.parameters(.udp)
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4 // wir sprechen nur IPv4
        let conn = NWConnection(host: .init(host), port: p, using: params)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(h, _)? = conn.currentPath?.remoteEndpoint, case .ipv4 = h, once.fire() {
                        cont.resume(returning: "\(h)".split(separator: "%").first.map(String.init))
                    }
                    conn.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if once.fire() { cont.resume(returning: nil); conn.cancel() } }
        }
    }

    private func findNode(at addrs: [(String, UInt16)]) {
        for (ip, port) in addrs {
            let target = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
            query(ip, port, "find_node", ["target": target]) { [weak self] r in
                guard let self, let r else { return }
                self.absorb(r)
            }
        }
    }

    private func absorb(_ r: [String: Any]) {
        guard let blob = BB.data(r["nodes"]) else { return }
        for (id, ip, port) in Self.parseCompactNodes(blob) { addCandidate(id, ip, port) }
    }

    private func tick() {
        ticks += 1
        let now = Date()
        for (k, p) in pending where p.deadline < now {
            pending[k] = nil
            fail(p.nodeID)
            p.done(nil)
        }
        let good = nodes.values.filter(\.good).count
        // Wenige Knoten (z. B. nur ein Router antwortet, wie hinter manchen VPNs/NATs): Router regelmäßig neu fragen.
        if good < 20, ticks % 8 == 0 { bootstrap() }
        // Wachsen: unbekannte Kandidaten anfragen, bis ein paar hundert verifiziert sind.
        // Danach nur noch langsam die ältesten prüfen (entfernt tote Knoten).
        let batch = good < 400 ? 40 : (ticks % 30 == 0 ? 4 : 0)
        if batch > 0 {
            let cutoff = now.addingTimeInterval(-60)
            let picks = nodes.values.filter { $0.lastQuery < cutoff }.sorted { $0.lastQuery < $1.lastQuery }.prefix(batch)
            for n in picks {
                let target = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
                query(n.ip, n.port, "find_node", ["target": target], nodeID: n.id) { [weak self] r in
                    if let r { self?.absorb(r) }
                }
            }
        }
        if ticks % 120 == 0 { saveNow() }
    }

    // MARK: - Persistenz

    private struct Saved: Codable {
        var id: String
        var nodes: [Entry]
        struct Entry: Codable { var id: String; var ip: String; var port: UInt16 }
    }

    private func load() {
        guard let storage, let raw = try? Data(contentsOf: storage),
              let s = try? JSONDecoder().decode(Saved.self, from: raw) else { return }
        // Anonymer Modus: kein stabiler Knoten-ID über Sitzungen hinweg (würde Sitzungen/VPN-Wechsel verknüpfen).
        if !NetworkPolicy.shared.anonymous, let id = MagnetLink.decodeHash(s.id) { myID = id }
        for e in s.nodes { if let id = MagnetLink.decodeHash(e.id) { addCandidate(id, e.ip, e.port) } }
    }

    private func saveNow() {
        guard let storage else { return }
        let good = nodes.values.filter(\.good).prefix(300)
        let s = Saved(id: NetworkPolicy.shared.anonymous ? "" : myID.hex, nodes: good.map { .init(id: $0.id.hex, ip: $0.ip, port: $0.port) })
        if let raw = try? JSONEncoder().encode(s) { try? raw.write(to: storage, options: .atomic) }
    }

    // MARK: - Peer-Suche

    /// Iterative Suche nach Peers für einen Info-Hash. `onPeers` kommt laufend (von einem DHT-Thread).
    /// Mit `announcePort` melden wir uns am Ende bei den nächsten Knoten als Peer an.
    public func lookup(infoHash: Data, announcePort: Int? = nil,
                       onPeers: @escaping @Sendable ([PeerAddress]) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            q.async { [self] in
                guard running else { cont.resume(); return }
                Lookup(dht: self, target: infoHash, announcePort: announcePort, onPeers: onPeers) { cont.resume() }.start()
            }
        }
    }

    private final class Lookup {
        struct Cand {
            let id: Data, ip: String, port: UInt16
            var state = 0   // 0 offen, 1 unterwegs, 2 geantwortet, 3 fehlgeschlagen
            var token: Data?
        }
        let dht: DHT
        let target: Data
        let announcePort: Int?
        let onPeers: @Sendable ([PeerAddress]) -> Void
        let finish: () -> Void
        var cands: [Data: Cand] = [:]
        var inflight = 0, sent = 0
        var finished = false
        var seen = Set<PeerAddress>()
        let deadline = Date().addingTimeInterval(25)

        init(dht: DHT, target: Data, announcePort: Int?, onPeers: @escaping @Sendable ([PeerAddress]) -> Void, finish: @escaping () -> Void) {
            self.dht = dht; self.target = target; self.announcePort = announcePort
            self.onPeers = onPeers; self.finish = finish
        }

        func start() {
            for n in dht.closest(to: target, 24) { cands[n.id] = Cand(id: n.id, ip: n.ip, port: n.port) }
            if cands.isEmpty { // Tabelle noch leer: direkt die Router fragen
                for (i, a) in dht.routerAddrs.enumerated() {
                    let id = Data([UInt8(i)] + [UInt8](repeating: 0xFF, count: 19))
                    cands[id] = Cand(id: id, ip: a.0, port: a.1)
                }
            }
            step()
        }

        private func sorted() -> [Cand] {
            let t = Array(target)
            func dist(_ id: Data) -> [UInt8] { zip(id, t).map { $0 ^ $1 } }
            return cands.values.filter { $0.state != 3 }.sorted { dist($0.id).lexicographicallyPrecedes(dist($1.id)) }
        }

        func step() {
            guard !finished else { return }
            if Date() > deadline || sent >= 150 { conclude(); return }
            let order = sorted()
            // Nur unter den 16 nächsten weitersuchen, sonst läuft die Suche in die Breite.
            for c in order.prefix(16) where c.state == 0 && inflight < 8 {
                cands[c.id]?.state = 1
                inflight += 1; sent += 1
                dht.query(c.ip, c.port, "get_peers", ["info_hash": target], nodeID: dht.nodes[c.id] != nil ? c.id : nil) { [self] r in
                    inflight -= 1
                    guard !finished else { return }
                    if let r {
                        cands[c.id]?.state = 2
                        cands[c.id]?.token = BB.data(r["token"])
                        if let values = r["values"] as? [Any] {
                            let fresh = DHT.parsePeers(values).filter { seen.insert($0).inserted }
                            if !fresh.isEmpty { onPeers(fresh) }
                        }
                        if let blob = BB.data(r["nodes"]) {
                            for (id, ip, port) in DHT.parseCompactNodes(blob) where cands[id] == nil && id != dht.myID {
                                cands[id] = Cand(id: id, ip: ip, port: port)
                                dht.addCandidate(id, ip, port)
                            }
                        }
                    } else {
                        cands[c.id]?.state = 3
                    }
                    step()
                }
            }
            // Fertig, wenn nichts mehr unterwegs ist und die 8 nächsten alle geantwortet haben (oder keine offenen mehr da sind).
            if inflight == 0 && !order.prefix(16).contains(where: { $0.state == 0 }) { conclude() }
        }

        func conclude() {
            guard !finished else { return }
            finished = true
            if let port = announcePort {
                for c in sorted().filter({ $0.state == 2 && $0.token != nil }).prefix(8) {
                    dht.query(c.ip, c.port, "announce_peer",
                              ["info_hash": target, "port": port, "token": c.token!, "implied_port": 0]) { _ in }
                }
            }
            finish()
        }
    }
}
