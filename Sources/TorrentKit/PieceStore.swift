import Foundation
import CryptoKit
import Network

/// Hält die heruntergeladenen Daten auf Platte und validiert Pieces (SHA-1).
/// Thread-sichere, synchron aufrufbare Klasse (NSLock).
public final class PieceStore: @unchecked Sendable {
    public let torrent: TorrentInfo
    public let rootURL: URL

    private let lock = NSLock()
    private var bitset: Data = Data()

    public init(torrent: TorrentInfo, rootURL: URL) {
        self.torrent = torrent
        self.rootURL = rootURL
        self.bitset = Data(repeating: 0, count: (torrent.numberOfPieces + 7) / 8)
    }

    // MARK: - Dateien

    /// Erzeugt (oder öffnet) alle Ziel-Files vorbelegt.
    public func prepareFiles() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for entry in torrent.entries where !entry.isDirectory {
            let url = rootURL.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        }
    }

    public func fileURL(for entry: TorrentEntry) -> URL {
        rootURL.appendingPathComponent(entry.path)
    }
    // MARK: - Piece-Geometrie

    public func pieceLength(_ index: Int) -> Int {
        let remaining = Int(torrent.totalSize) - index * torrent.pieceLength
        return max(0, min(torrent.pieceLength, remaining))
    }

    /// File, das den Byte-Bereich [offset, offset+length) vollständig deckt (wenn es existiert).
    public func entryCovering(_ offset: Int, _ length: Int) -> TorrentEntry? {
        torrent.entries.first {
            offset >= $0.pieceOffset && offset + length <= $0.pieceOffset + $0.length
        }
    }

    /// Schreibt ein komplettes Piece an die korrekte Stelle im File.
    public func writePieceBytes(_ data: Data, index: Int) -> Bool {
        let length = pieceLength(index)
        guard data.count == length, length > 0 else { return false }
        // Piece kann mehrere Dateien überspannen → aufgeteilt schreiben.
        var written = 0
        let start = index * torrent.pieceLength
        for entry in torrent.entries {
            let fileStart = entry.pieceOffset
            let fileEnd = fileStart + entry.length
            guard fileStart < start + length, fileEnd > start else { continue }
            let s = max(start, fileStart)
            let e = min(start + length, fileEnd)
            let chunk = Data(data[(s - start) ..< (e - start)])
            guard let handle = FileHandle(forWritingAtPath: fileURL(for: entry).path) else { return false }
            do {
                try handle.seek(toOffset: UInt64(s - fileStart))
                try handle.write(contentsOf: Data(chunk))
            } catch { return false }
            try? handle.close()
            written += e - s
        }
        return written == length
    }

    /// Liest einen Ausschnitt eines validierten Pieces von Platte (für Uploads).
    public func readSlice(offset: Int, length: Int) -> Data? {
        guard length > 0 else { return nil }
        // Alle Dateien, die den Ausschnitt berühren, zusammenlesen.
        var out = Data()
        for entry in torrent.entries {
            let fileStart = entry.pieceOffset
            let fileEnd = entry.pieceOffset + entry.length
            guard fileStart < offset + length && fileEnd > offset else { continue }
            let s = max(offset, fileStart)
            let e = min(offset + length, fileEnd)
            guard let data = try? Data(contentsOf: fileURL(for: entry)) else { return nil }
            out.append(data[(s - fileStart)..<(e - fileStart)])
        }
        return out.count == length ? out : nil
    }

    // MARK: - Validierung

    /// SHA-1 eines Pieces aus der Platte.
    public func validatePiece(_ index: Int) -> Bool {
        let offset = index * torrent.pieceLength
        let length = pieceLength(index)
        guard length > 0,
              let data = readSlice(offset: offset, length: length) else { return false }
        let hash = Data(Insecure.SHA1.hash(data: data))
        return hash == torrent.pieceHashes[index]
    }

    public func setValid(_ index: Int, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < bitset.count * 8 else { return }
        if value { bitset[index / 8] |= (1 << (7 - index % 8)) }
        else { bitset[index / 8] &= ~(1 << (7 - index % 8)) }
    }

    public func isPieceValid(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < bitset.count * 8 else { return false }
        return bitset[index / 8] & (1 << (7 - index % 8)) != 0
    }

    /// Bitfield im BitTorrent-Format (piece 0 = erstes Bit).
    public func validBitfield() -> Data {
        lock.lock(); defer { lock.unlock() }
        return bitset
    }

    public var validatedCount: Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        for i in 0..<torrent.numberOfPieces where bit(i) { n += 1 }
        return n
    }

    public func pendingPieceList() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return (0..<torrent.numberOfPieces).filter { !bit($0) }
    }

    private func bit(_ i: Int) -> Bool {
        guard i >= 0, i < bitset.count * 8 else { return false }
        return bitset[i / 8] & (1 << (7 - i % 8)) != 0
    }
}
