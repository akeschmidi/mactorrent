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
        let pieceHashes = stride(from: 0, to: piecesData.count, by: 20).map { piecesData[$0..<$0 + 20] }

        // Dateien: entweder "name" + "length" (einfach) oder "files" (mehrere)
        var entries: [TorrentEntry] = []
        var totalSize: Int64 = 0
        var name = "torrent"
        var isMultifile = false

        if let files = BB.list(info["files"]) {
            isMultifile = true
            name = "multi"
            var runningOffset = 0
            for f in files {
                guard let fd = f as? [String: Any] else { continue }
                guard let pathArr = BB.list(fd["path"]) else { continue }
                let path = pathArr.compactMap { BB.string($0) }.joined(separator: "/")
                let len = BB.int(fd["length"]) ?? 0
                entries.append(TorrentEntry(path: path, pieceOffset: runningOffset, length: len))
                runningOffset += len
                totalSize += Int64(len)
            }
        } else {
            name = BB.string(info["name"]) ?? "file"
            let len = BB.int(info["length"]) ?? 0
            entries.append(TorrentEntry(path: name, pieceOffset: 0, length: len))
            totalSize = Int64(len)
        }

        // Tracker-URLs (announce + announce-list)
        var trackers: [URL] = []
        if let announce = BB.string(rootDict["announce"]), let u = URL(string: announce) {
            trackers.append(u)
        }
        if let announceList = rootDict["announce-list"] as? [Any] {
            for group in announceList {
                if let urls = group as? [Any] {
                    for u in urls {
                        if let s = BB.string(u), let url = URL(string: s) { trackers.append(url) }
                    }
                }
            }
        }

        let created: Date? = BB.int(rootDict["creation date"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return TorrentInfo(
            name: name,
            infoHash: infoHash,
            infoHashHex: infoHashHex,
            pieceLength: pieceLen,
            pieceHashes: pieceHashes,
            entries: entries,
            totalSize: totalSize,
            trackerURLs: trackers,
            created: created
        )
    }
}

extension Data {
    /// Hex-Repräsentation (klein).
    public var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
