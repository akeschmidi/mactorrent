import Foundation

/// Ein Eintrag in einem Torrentfile.
public struct TorrentEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String            // relativer Pfad (UTF-8, "/"-getrennt)
    public let pieceOffset: Int        // Byte-Offset in der Piece-Abfolge
    public let length: Int
    public let isDirectory: Bool

    public init(id: UUID = UUID(), path: String, pieceOffset: Int, length: Int, isDirectory: Bool = false) {
        self.id = id
        self.path = path
        self.pieceOffset = pieceOffset
        self.length = length
        self.isDirectory = isDirectory
    }
}

/// Ein dekodierter .torrent.
public struct TorrentInfo: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let infoHash: Data
    public let infoHashHex: String
    public let pieceLength: Int
    public let pieceHashes: [Data]
    public let entries: [TorrentEntry]
    public let totalSize: Int64
    public let trackerURLs: [URL]
    public let created: Date?

    public var numberOfPieces: Int { pieceHashes.count }
    public var numberOfFiles: Int { entries.filter { !$0.isDirectory }.count }

    public init(id: UUID = UUID(), name: String, infoHash: Data, infoHashHex: String,
                pieceLength: Int, pieceHashes: [Data], entries: [TorrentEntry],
                totalSize: Int64, trackerURLs: [URL], created: Date?) {
        self.id = id
        self.name = name
        self.infoHash = infoHash
        self.infoHashHex = infoHashHex
        self.pieceLength = pieceLength
        self.pieceHashes = pieceHashes
        self.entries = entries
        self.totalSize = totalSize
        self.trackerURLs = trackerURLs
        self.created = created
    }
}

/// Fortschritt eines Torrents.
public struct TransferProgress: Equatable, Sendable {
    public var downloadedBytes: Int64
    public var downloadedPieces: Int
    public var totalPieces: Int
    public var uploadedBytes: Int64
    public var peers: Int
    public var isDone: Bool
    public var downSpeed: Int64 = 0   // Bytes/s
    public var upSpeed: Int64 = 0     // Bytes/s

    public var fraction: Double {
        totalPieces == 0 ? 0 : Double(downloadedPieces) / Double(totalPieces)
    }
}

public enum TorrentError: Error, CustomStringConvertible {
    case notATorrent
    case missingInfoDict
    case invalidPieceHash
    case unsupportedFormat
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case .notATorrent: "File ist kein gültiges .torrent (bencode)"
        case .missingInfoDict: "info-Dictionary fehlt"
        case .invalidPieceHash: "Stückweises Hash (20 Bytes) fehlt"
        case .unsupportedFormat: "Format nicht unterstützt"
        case .alreadyRunning: "Torrent läuft bereits"
        case .notRunning: "Torrent läuft nicht"
        }
    }
}
