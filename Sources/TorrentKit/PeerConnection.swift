import Foundation
import Network

/// BitTorrent Peer-Protokoll über TCP (Network.framework).
/// Alle Netzwerk-Operationen laufen auf einer privaten serialen Queue
/// (Thread-Sicherheit über die Queue, daher @unchecked Sendable).
/// Events gehen an die Engine per AsyncThrowingStream.
public final class PeerConnection: @unchecked Sendable {
    /// Handshake ist 68 Bytes (1 Header + 19 Protokoll + 8 Res + 20 InfoHash + 20 PeerID + 8 Extension).
    static let handshakeLength = 68

    private let infoHash: Data
    private let peerID: Data

    private let netQueue: DispatchQueue = DispatchQueue(label: "pconn.net")
    private var conn: NWConnection?
    private var buffer = Data()
    private var handshakeDone = false
    private var closedFlag = false

    private let contLock = NSLock()
    private var continuation: AsyncThrowingStream<PeerEvent, Error>.Continuation?

    public init(infoHash: Data, peerID: Data) {
        guard infoHash.count == 20 else { fatalError("infoHash muss 20 Bytes lang sein") }
        self.infoHash = infoHash
        self.peerID = peerID
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
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let endpoint = NWEndpoint.hostPort(host: .name(host, nil), port: endpointPort)
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.conn = conn

        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                self?.sendHandshake()
                self?.recurseReceive()
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
        var hs = Data()
        hs.append(UInt8(19))
        hs.append("BitTorrent".data(using: .utf8)!)
        hs.append(Data(count: 8)) // reserved
        hs.append(infoHash)
        hs.append(peerID)
        hs.append(Data(count: 8)) // extension field
        sendRaw(hs)
    }

    // MARK: - Receive + Frame-Parsing

    private func recurseReceive() {
        guard let conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.received(data)
            }
            if let error {
                self.fatal(error.localizedDescription)
                return
            }
            if !self.closedFlag {
                self.recurseReceive()
            }
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
                    fatal("Frame zu groß: \(len)")
                    return
                }
                guard buffer.count >= 4 + len else { break }
                let msg = buffer.subdata(in: 4..<(4 + len))
                buffer.removeSubrange(0..<(4 + len))
                yield(.message(msg))
            } else {
                guard buffer.count >= Self.handshakeLength else { break }
                let hs = buffer.prefix(Self.handshakeLength)
                buffer.removeSubrange(0..<Self.handshakeLength)
                let remoteHash = hs.subdata(in: 24..<44)
                let remotePeerID = hs.subdata(in: 44..<64)
                if remoteHash != infoHash {
                    fatal("InfoHash stimmt nicht")
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

public enum PeerError: Error, CustomStringConvertible {
    case notConnected
    case connectionLost(String)

    public var description: String {
        switch self {
        case .notConnected: "Peer nicht verbunden"
        case .connectionLost(let r): "Peer-Verbindung verloren: \(r)"
        }
    }
}
