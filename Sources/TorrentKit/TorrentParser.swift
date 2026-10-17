import Foundation
import CryptoKit

public struct TorrentParser {
    /// Dekodiert ein .torrentfile zu einer `TorrentInfo`.
    public static func parse(_ data: Data) throws -> TorrentInfo {
        let root = try BB.decodeTolerant(data)
        guard let rootDict = root as? [String: Any] else { throw TorrentError.notATorrent }
        guard let info = rootDict["info"] as? [String: Any] else { throw TorrentError.missingInfoDict }

        // infoHash = SHA-1 des bencodierten info-Dict (exakt wie im File gespeichert)
        let infoBytes = try BB.encode(info)
        let infoHash = Data(Insecure.SHA1.hash(data: infoBytes))
        let infoHashHex = infoHash.hex

        guard let pieceLen = BB.int(info["piece length"]), pieceLen > 0 else { throw TorrentError.invalidPieceHash }
        guard let piecesData = BB.data(info["pieces"]), piecesData.count >= 20, piecesData.count % 20 == 0 else {
            throw TorrentError.invalidPieceHash
        }

        // Dateien: entweder "name" + "length" (einfach) oder "files" (mehrere)
        var entries: [TorrentEntry] = []
        var totalSize: Int64 = 0
        var name = "torrent"
        var isMultifile = false

        if let files = BB.list(info["files"]) {
            isMultifile = true
            name = sanitizedName(BB.string(info["name"]))
            var runningOffset = 0
            for f in files {
                guard let fd = f as? [String: Any] else { continue }
                guard let pathArr = BB.list(fd["path"]) else { continue }
                // Jeder Pfadteil kommt aus fremder Hand: "..", "/" & Co. würden aus dem Download-Ordner ausbrechen.
                let parts = pathArr.compactMap { BB.string($0) }
                guard !parts.isEmpty, parts.count == pathArr.count, parts.allSatisfy(isSafeComponent) else {
                    throw TorrentError.unsafePath
                }
                let path = parts.joined(separator: "/")
                let len = BB.int(fd["length"]) ?? 0
                guard len >= 0 else { throw TorrentError.unsupportedFormat }
                entries.append(TorrentEntry(path: path, pieceOffset: runningOffset, length: len))
                runningOffset += len
                totalSize += Int64(len)
            }
        } else {
            name = sanitizedName(BB.string(info["name"]))
            let len = BB.int(info["length"]) ?? 0
            guard len >= 0 else { throw TorrentError.unsupportedFormat }
            entries.append(TorrentEntry(path: name, pieceOffset: 0, length: len))
            totalSize = Int64(len)
        }

        // Tracker-URLs (announce + announce-list), ohne Duplikate.
        var trackers: [URL] = []
        func addTracker(_ url: URL) {
            if !trackers.contains(url) { trackers.append(url) }
        }
        if let announce = BB.string(rootDict["announce"]), let u = URL(string: announce) {
            addTracker(u)
        }
        if let announceList = rootDict["announce-list"] as? [Any] {
            for group in announceList {
                if let urls = group as? [Any] {
                    for u in urls {
                        if let s = BB.string(u), let url = URL(string: s) { addTracker(url) }
                    }
                }
            }
        }
        let isPrivate = (BB.int(info["private"]) ?? 0) == 1

        let created: Date? = BB.int(rootDict["creation date"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return TorrentInfo(
            name: name,
            infoHash: infoHash,
            infoHashHex: infoHashHex,
            pieceLength: pieceLen,
            pieceHashes: piecesData,
            entries: entries,
            totalSize: totalSize,
            trackerURLs: trackers,
            isPrivate: isPrivate,
            created: created
        )
    }
}

extension TorrentParser {
    /// Ein einzelner Pfadteil ist nur dann sicher, wenn er weder Verzeichnis wechselt noch Trenner/Steuerzeichen enthält.
    static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.utf8.count <= 255
            && !s.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Torrent-Name als Ordner-/Dateiname: Trenner und Steuerzeichen werden ersetzt, "." / ".." / leer → "torrent".
    public static func sanitizedName(_ raw: String?) -> String {
        var s = String((raw ?? "").unicodeScalars.map { c -> Character in
            c == "/" || c == "\\" || c.value < 0x20 || c.value == 0x7F ? "–" : Character(c)
        })
        s = s.trimmingCharacters(in: .whitespaces)
        // Kein führender Punkt: der Name wird Ordner direkt im Download-Ordner (`.ssh`, `.config` …).
        while s.hasPrefix(".") { s.removeFirst() }
        if s.utf8.count > 255 { s = String(s.prefix(100)) }
        return (s.isEmpty || s == "." || s == "..") ? "torrent" : s
    }
}

extension Data {
    /// Hex-Repräsentation (klein).
    public var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
