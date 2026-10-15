import Foundation
import Network

/// BitTorrent Peer-Protokoll über TCP (Network.framework).
/// Alle Netzwerk-Operationen laufen auf einer privaten serialen Queue
/// (Thread-Sicherheit über die Queue, daher @unchecked Sendable).
/// Events gehen an die Engine per AsyncThrowingStream.
public final class PeerConnection: @unchecked Sendable {
    /// Handshake ist 68 Bytes: pstrlen, "BitTorrent protocol", 8 reserved, info_hash, peer_id.
    static let handshakeLength = 68

    private let infoHash: Data
    private let peerID: Data
    /// BEP 10: setzt das Extension-Bit im Handshake (nötig für Magnet-Metadaten).
    private let extensions: Bool

    private let netQueue: DispatchQueue
    private var conn: NWConnection?
    private var buffer = Data()
    private var handshakeDone = false
    private var closedFlag = false
    private var didStartIO = false

    private let contLock = NSLock()
    private var continuation: AsyncThrowingStream<PeerEvent, Error>.Continuation?

    public init(infoHash: Data, peerID: Data, extensions: Bool = false, queue: DispatchQueue? = nil) {
        self.extensions = extensions
        self.netQueue = queue ?? DispatchQueue(label: "pconn.net")
        guard infoHash.count == 20 else { fatalError("infoHash muss 20 Bytes lang sein") }
        self.infoHash = infoHash
        self.peerID = peerID
    }

    /// Eingehende Verbindung (vom Listener der Engine angenommen).
    /// Eingehende Verbindung, die der `PeerListener` schon gestartet und deren Handshake er gelesen hat.
    convenience init(infoHash: Data, peerID: Data, accepted: NWConnection) {
        self.init(infoHash: infoHash, peerID: peerID, queue: PeerListener.shared.queue)
        self.conn = accepted
    }

    /// Erzeugt einen Event-Stream, der alle noch laufenden Events bringt.
    /// (Peers-Loop ruft das pro Verbindung einmal auf.)
    public func makeStream() -> AsyncThrowingStream<PeerEvent, Error> {
        let (stream, cont) = AsyncThrowingStream.makeStream(of: PeerEvent.self)
        contLock.lock()
        continuation = cont
        contLock.unlock()
        return stream
    }

    // MARK: - Lifecycle

    /// Startet die TCP-Verbindung zum Peer.
    public func start(host: String, port: Int) {
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { fatal(String(localized: "ungültiger Port", bundle: .main)); return }
        let endpoint = NWEndpoint.hostPort(host: .name(host, nil), port: endpointPort)
        guard !NetworkPolicy.shared.isBlocked else { fatal(String(localized: "VPN-Schutz: Schnittstelle nicht verbunden", bundle: .main)); return }
        let conn = NWConnection(to: endpoint, using: NetworkPolicy.shared.parameters(.tcp))
        self.conn = conn
        attach(conn)
    }

    /// Startet eine angenommene Verbindung: eigenen Handshake senden, die schon gelesenen Bytes verarbeiten, weiterlesen.
    func startAccepted(preread: Data) {
        netQueue.async { [self] in
            guard let conn, !closedFlag else { return }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e): self?.fatal(e.localizedDescription)
                case .cancelled: self?.fatal("verbindung abgebrochen")
                default: break
                }
            }
            didStartIO = true
            sendHandshake()
            received(preread)
            recurseReceive()
        }
    }

    private func attach(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                guard let self, !self.didStartIO else { return }
                self.didStartIO = true
                self.sendHandshake()
                self.recurseReceive()
            case .waiting(let error):
                let text = String(describing: error)
                if text.contains("refused") || text.contains("ECONNREFUSED") {
                    self?.fatal("Verbindung abgelehnt")
                }
            case .failed(let error):
                self?.fatal(error.localizedDescription)
            case .cancelled:
                self?.fatal("verbindung abgebrochen")
            default:
                break
            }
        }
        conn.start(queue: netQueue)
    }

    /// Beendet die Verbindung sauber.
    public func close() {
        closedFlag = true
        netQueue.async { [weak self] in
            self?.conn?.cancel()
            self?.finishStream(nil)
        }
    }

    private func finishStream(_ error: Error?) {
        contLock.lock()
        let cont = continuation
        continuation = nil
        contLock.unlock()
        if let cont {
            if let error { cont.finish(throwing: error) }
            else { cont.finish() }
        }
    }

    private func fatal(_ reason: String) {
        if closedFlag { return }
        closedFlag = true
        conn?.cancel()
        finishStream(PeerError.connectionLost(reason))
    }

    private func yield(_ event: PeerEvent) {
        contLock.lock()
        let cont = continuation
        contLock.unlock()
        cont?.yield(event)
    }

    // MARK: - Handshake

    private func sendHandshake() {
        var hs = Data([19])
        hs.append(Data("BitTorrent protocol".utf8))
        var reserved = Data(count: 8)
        if extensions { reserved[5] = 0x10 }
        hs.append(reserved)
        hs.append(infoHash)
        hs.append(peerID)
        sendRaw(hs)
    }

    // MARK: - Receive + Frame-Parsing

    private func recurseReceive() {
        guard let conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.received(data)
            }
            if self.closedFlag { return }
            // isComplete heißt: der Peer hat den Stream geschlossen. Ein weiterer receive
            // erzeugt nur „already delivered final read“ / „No message available on STREAM“.
            if isComplete {
                self.fatal(String(localized: "Peer hat die Verbindung geschlossen", bundle: .main))
                return
            }
            if let error {
                let text = error.localizedDescription
                self.fatal(text.contains("No message available") ? String(localized: "Peer hat den Stream geschlossen", bundle: .main) : text)
                return
            }
            self.recurseReceive()
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while true {
            if handshakeDone {
                // Frames: [4-byte length][payload, inkl. 1 Byte Type]
                guard buffer.count >= 4 else { break }
                let len = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])
                guard len <= 4 * 1024 * 1024 else {
                    fatal(String(localized: "Frame zu groß: \(len)", bundle: .main))
                    return
                }
                guard buffer.count >= 4 + len else { break }
                let msg = buffer.subdata(in: 4..<(4 + len))
                buffer.removeSubrange(0..<(4 + len))
                yield(.message(msg))
            } else {
                guard buffer.count >= Self.handshakeLength else { break }
                let hs = Data(buffer.prefix(Self.handshakeLength))
                buffer.removeSubrange(0..<Self.handshakeLength)
                guard hs[0] == 19 else {
                    fatal(String(localized: "Handshake ungültig", bundle: .main))
                    return
                }
                let remoteHash = hs.subdata(in: 28..<48)
                let remotePeerID = hs.subdata(in: 48..<68)
                if remoteHash != infoHash {
                    fatal(String(localized: "InfoHash stimmt nicht", bundle: .main))
                    return
                }
                handshakeDone = true
                yield(.handshake(String(decoding: remotePeerID, as: UTF8.self)))
            }
        }
    }

    // MARK: - Send

    /// Sendet einen Message-Frame (ohne Length-Prefix; wird intern ergänzt).
    public func send(_ frame: Data) throws {
        if closedFlag { throw PeerError.notConnected }
        var full = Data()
        full.append(UInt8((frame.count >> 24) & 0xFF))
        full.append(UInt8((frame.count >> 16) & 0xFF))
        full.append(UInt8((frame.count >> 8) & 0xFF))
        full.append(UInt8(frame.count & 0xFF))
        full.append(frame)
        netQueue.async { [weak self] in
            guard let self, let conn = self.conn else { return }
            conn.send(content: full, completion: .contentProcessed { error in
                if let error {
                    self.fatal(error.localizedDescription)
                }
            })
        }
    }

    /// Bildet einen Message-Frame: [1-byte type][payload].
    public static func frame(_ type: UInt8, _ payload: Data = Data()) -> Data {
        var f = Data([type])
        f.append(payload)
        return f
    }

    private func sendRaw(_ data: Data) {
        netQueue.async { [weak self] in
            guard let self, let conn = self.conn else { return }
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    self.fatal(error.localizedDescription)
                }
            })
        }
    }
}

public enum PeerEvent: Sendable {
    case handshake(String)
    case message(Data)
}

public enum PeerError: Error, CustomStringConvertible, LocalizedError {
    case notConnected
    case connectionLost(String)

    public var description: String {
        switch self {
        case .notConnected: String(localized: "Peer nicht verbunden", bundle: .main)
        case .connectionLost(let r): String(localized: "Peer-Verbindung verloren: \(r)", bundle: .main)
        }
    }

    public var errorDescription: String? { description }
}
