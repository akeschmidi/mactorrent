import Foundation

/// Laufzeit-Zustand eines Downloads.
public enum EngineState: Equatable, Sendable {
    case idle
    case scanning
    case downloading
    case done
    case paused
    case failed(String)
}

/// Ereignisse, die die Engine an die UI meldet.
public enum EngineEvent: Sendable {
    case state(EngineState)
    case progress(downloaded: Int64, pieces: Int, totalPieces: Int, uploaded: Int64, downSpeed: Int64, upSpeed: Int64, peers: Int)
    case error(String)
    case log(String)
}

/// Ein Peer (IP:Port) aus einer Tracker-Antwort.
public struct PeerAddress: Hashable, Sendable {
    public let ip: String
    public let port: Int
    public var label: String { "\(ip):\(port)" }
    public init(ip: String, port: Int) { self.ip = ip; self.port = port }
}
