import Foundation
import CryptoKit
import Network

/// Hält die heruntergeladenen Daten auf Platte und validiert Pieces (SHA-1).
/// Thread-sichere, synchron aufrufbare Klasse (NSLock).
public final class PieceStore: @unchecked Sendable {
    public let torrent: TorrentInfo
    private var root: URL
    public var rootURL: URL { lock.lock(); defer { lock.unlock() }; return root }

    private let lock = NSLock()
    private var bitset: Data = Data()
    private var validCount = 0
    private var validByteCount: Int64 = 0
    /// Dateiauswahl: welche Pieces gebraucht werden (alle, solange nichts abgewählt ist) und die zugehörigen Zähler.
    private var wantedMask: [Bool]
    private var wantedTotal: Int
    private var wantedValidCount = 0
    private var wantedTotalBytes: Int64
    private var wantedValidByteCount: Int64 = 0
    /// Gespeicherter Bitfield: ein Neustart hasht die Dateien nicht noch einmal.
    private var trustedBitfield = false

    public init(torrent: TorrentInfo, rootURL: URL) {
        self.torrent = torrent
        self.root = rootURL
        self.bitset = Data(repeating: 0, count: (torrent.numberOfPieces + 7) / 8)
        self.wantedMask = Array(repeating: true, count: torrent.numberOfPieces)
        self.wantedTotal = torrent.numberOfPieces
        self.wantedTotalBytes = torrent.totalSize
    }

    // MARK: - Dateien

    /// Erzeugt (oder öffnet) alle Ziel-Files vorbelegt.
    public func prepareFiles() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // Zweite Sicherung neben dem Parser: jede Datei muss unter dem Wurzelordner bleiben.
        let base = rootURL.standardizedFileURL.path + "/"
        for entry in torrent.entries where !entry.isDirectory {
            guard fileURL(for: entry).standardizedFileURL.path.hasPrefix(base) else { throw TorrentError.unsafePath }
        }
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

    /// Zeigt nach einem Verschieben auf den neuen Ordner.
    public func relocate(to url: URL) {
        lock.lock(); root = url; lock.unlock()
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

    /// Liest einen Ausschnitt von Platte (Uploads und Piece-Prüfung).
    /// Zu kurze oder fehlende Dateien liefern nil. Der Data-Subscript würde sonst
    /// mit EXC_BREAKPOINT abbrechen — prepareFiles legt die Dateien leer an.
    public func readSlice(offset: Int, length: Int) -> Data? {
        guard length > 0, offset >= 0, offset <= Int.max - length else { return nil }
        var out = Data()
        out.reserveCapacity(length)
        for entry in torrent.entries where !entry.isDirectory && entry.length > 0 {
            let fileStart = entry.pieceOffset
            let fileEnd = fileStart + entry.length
            guard fileStart < offset + length, fileEnd > offset else { continue }
            let s = max(offset, fileStart)
            let e = min(offset + length, fileEnd)
            let local = s - fileStart
            let count = e - s
            guard count > 0, local >= 0 else { return nil }
            guard let chunk = readFileRange(fileURL(for: entry), offset: local, count: count) else { return nil }
            out.append(chunk)
        }
        return out.count == length ? out : nil
    }

    /// Liest genau `count` Bytes. Ein kurzer Read (Datei kürzer als im Torrent) ist nil, kein Trap.
    private func readFileRange(_ url: URL, offset: Int, count: Int) -> Data? {
        guard offset >= 0, count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Validierung

    /// SHA-1 eines Pieces aus der Platte.
    public func validatePiece(_ index: Int) -> Bool {
        let offset = index * torrent.pieceLength
        let length = pieceLength(index)
        guard length > 0,
              let data = readSlice(offset: offset, length: length) else { return false }
        let hash = Data(Insecure.SHA1.hash(data: data))
        return hash == torrent.pieceHash(index)
    }

    public func setValid(_ index: Int, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < bitset.count * 8, bit(index) != value else { return }
        if value { bitset[index / 8] |= (1 << (7 - index % 8)) }
        else { bitset[index / 8] &= ~(1 << (7 - index % 8)) }
        // Zähler mitführen: validatedCount lief sonst bei jedem Block über alle Pieces.
        validCount += value ? 1 : -1
        validByteCount += Int64(value ? pieceLength(index) : -pieceLength(index))
        if wantedMask[index] {
            wantedValidCount += value ? 1 : -1
            wantedValidByteCount += Int64(value ? pieceLength(index) : -pieceLength(index))
        }
    }

    // MARK: - Dateiauswahl

    /// `files[i]` = Datei i (Reihenfolge von `torrent.entries`) wird gewünscht. Ein Piece zählt, sobald es
    /// mindestens eine gewünschte Datei berührt.
    public func setWanted(files: [Bool]) {
        lock.lock(); defer { lock.unlock() }
        let n = torrent.numberOfPieces
        var mask = Array(repeating: false, count: n)
        for (i, e) in torrent.entries.enumerated() where !e.isDirectory && e.length > 0 && (i >= files.count || files[i]) {
            let first = e.pieceOffset / torrent.pieceLength
            let last = min(n - 1, (e.pieceOffset + e.length - 1) / torrent.pieceLength)
            if first <= last { for p in first...last { mask[p] = true } }
        }
        // Torrents ohne Dateien (nur leere Einträge) bleiben wie sie waren.
        wantedMask = mask
        recountWanted()
    }

    private func recountWanted() {
        wantedTotal = 0; wantedValidCount = 0; wantedTotalBytes = 0; wantedValidByteCount = 0
        for i in 0..<torrent.numberOfPieces where wantedMask[i] {
            wantedTotal += 1
            wantedTotalBytes += Int64(pieceLength(i))
            if bit(i) { wantedValidCount += 1; wantedValidByteCount += Int64(pieceLength(i)) }
        }
    }

    public func isWanted(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index >= 0 && index < wantedMask.count && wantedMask[index]
    }

    /// Alle gewünschten Pieces sind geprüft.
    public var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return wantedValidCount == wantedTotal }
    /// `restore` hat einen passenden Bitfield gesetzt. Der Start darf die Platte dann nicht neu lesen.
    public var hasTrustedBitfield: Bool { lock.lock(); defer { lock.unlock() }; return trustedBitfield }
    public var wantedPieceCount: Int { lock.lock(); defer { lock.unlock() }; return wantedTotal }
    public var wantedValidPieceCount: Int { lock.lock(); defer { lock.unlock() }; return wantedValidCount }
    public var wantedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return wantedTotalBytes }
    public var wantedValidBytes: Int64 { lock.lock(); defer { lock.unlock() }; return wantedValidByteCount }

    /// Stellt einen gespeicherten Stand wieder her (Länge muss passen, sonst ignoriert).
    public func restore(bitfield: Data) {
        guard bitfield.count == (torrent.numberOfPieces + 7) / 8 else { return }
        lock.lock(); defer { lock.unlock() }
        bitset = bitfield
        trustedBitfield = true
        validCount = 0; validByteCount = 0
        for i in 0..<torrent.numberOfPieces where bit(i) {
            validCount += 1
            validByteCount += Int64(pieceLength(i))
        }
        recountWanted()
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
        return validCount
    }

    /// Bytes der geprüften Pieces (bleibt nach Neustart korrekt, anders als Session-Bytes).
    public var validatedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return validByteCount
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
