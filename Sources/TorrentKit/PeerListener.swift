import Foundation
import Network

/// Ein gemeinsamer TCP-Listener für alle Torrents (ein Port zum Weiterleiten im Router).
/// Liest den 68-Byte-Handshake, sucht über den Info-Hash den passenden Torrent und übergibt die Verbindung samt
/// bereits gelesenen Bytes. Läuft, solange mindestens ein Torrent angemeldet ist.
public final class PeerListener: @unchecked Sendable {
    public static let shared = PeerListener()
    /// Serielle Queue für alle angenommenen Verbindungen (PeerConnection nutzt sie als eigene Queue).
    let queue = DispatchQueue(label: "ch.stefan.mactorrent.listener")
    public typealias Handler = @Sendable (NWConnection, Data) -> Void

    private let lock = NSLock()
    private var listener: NWListener?
    private var ready = false
    private var handlers: [Data: Handler] = [:]
    private var activePort = 0

    public var port: Int { lock.lock(); defer { lock.unlock() }; return activePort }

    // Sync-Helfer: NSLock darf nicht direkt in async-Code stehen.
    private func store(_ h: @escaping Handler, for hash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        handlers[hash] = h
        return listener != nil
    }
    private func setReady(_ v: Bool) { lock.lock(); ready = v; lock.unlock() }
    private var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    /// Übernimmt den Listener, falls ein anderer Torrent nicht schneller war. Rückgabe: aktiver Port.
    private func commit(_ l: NWListener, port p: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if listener == nil { listener = l; activePort = p } else { l.cancel() }
        return activePort
    }

    /// Meldet einen Torrent an und startet bei Bedarf den Listener. `preferred` 0 = zufällig aus 6881–6999.
    /// Rückgabe: der Port, oder 0 wenn keiner geöffnet werden konnte (z. B. gewünschter Port belegt).
    public func register(infoHash: Data, preferred: Int, handler: @escaping Handler) async -> Int {
        if store(handler, for: infoHash) { return port }
        let candidates = preferred > 0 ? [preferred] : Array((6881...6999).shuffled().prefix(20))
        for p in candidates {
            guard let np = NWEndpoint.Port(rawValue: UInt16(p)),
                  let l = try? NWListener(using: NetworkPolicy.shared.parameters(.tcp), on: np) else { continue }
            setReady(false)
            l.stateUpdateHandler = { [weak self] st in
                if case .ready = st { self?.setReady(true) }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            for _ in 0..<20 where !isReady { try? await Task.sleep(for: .milliseconds(50)) }
            if isReady { return commit(l, port: p) }
            l.cancel() // Port belegt: nächsten probieren
        }
        return 0
    }

    public func unregister(infoHash: Data) {
        lock.lock()
        handlers[infoHash] = nil
        let stop = handlers.isEmpty ? listener : nil
        if stop != nil { listener = nil; activePort = 0; ready = false }
        lock.unlock()
        stop?.cancel()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let once = Once()
        // Wer in 10 s keinen Handshake schickt, fliegt raus.
        queue.asyncAfter(deadline: .now() + 10) { if once.fire() { conn.cancel() } }
        conn.receive(minimumIncompleteLength: 68, maximumLength: 68) { [weak self] data, _, _, _ in
            guard once.fire() else { return }
            guard let self, let data, data.count == 68, data[data.startIndex] == 19 else { conn.cancel(); return }
            let hash = Data(data[data.startIndex + 28 ..< data.startIndex + 48])
            self.lock.lock(); let h = self.handlers[hash]; self.lock.unlock()
            if let h { h(conn, data) } else { conn.cancel() }
        }
    }
}
