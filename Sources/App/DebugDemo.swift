#if DEBUG
import Foundation
import TorrentKit

/// Nur Debug (`--demo`): ein paar Fake-Torrents mit Fortschritt, um die Oberfläche zu prüfen. Wird nie gespeichert.
extension AppModel {
    func loadDemo() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func make(_ name: String, gb: Double, done: Double, files: [(String, Int)]? = nil, run: Bool) {
            let pieceLength = 4 * 1024 * 1024
            let total = Int(gb * 1_073_741_824)
            let n = max(1, total / pieceLength)
            var info: [String: Any] = ["name": name, "piece length": pieceLength,
                                       "pieces": Data((0..<(n * 20)).map { _ in UInt8.random(in: 0...255) })]
            if let files {
                var rest = n * pieceLength
                info["files"] = files.enumerated().map { i, f -> [String: Any] in
                    let len = i == files.count - 1 ? rest : min(rest, f.1 * 1_048_576)
                    rest -= len
                    return ["length": len, "path": [f.0]]
                }
            } else {
                info["length"] = n * pieceLength
            }
            guard let data = try? BB.encode(["announce": "http://127.0.0.1:1/a", "info": info] as [String: Any]),
                  let t = try? TorrentParser.parse(data) else { return }
            let engine = TorrentEngine(torrent: t, rootURL: base.appendingPathComponent(name))
            var bits = Data(repeating: 0, count: (n + 7) / 8)
            for i in 0..<Int(Double(n) * done) { bits[i / 8] |= 1 << (7 - i % 8) }
            engine.restoreBitfield(bits)
            let file = base.appendingPathComponent(t.infoHashHex + ".torrent")
            try? data.write(to: file, options: .atomic)
            items.append(Item(name: name, torrent: t, torrentFile: file, engine: engine))
            if run { Task { await engine.start() } }
        }
        make("ubuntu-24.04.1-desktop-amd64.iso", gb: 5.8, done: 0.33, run: true)
        make("Sintel (2010) 1080p", gb: 1.2, done: 1.0, files: [("Sintel.mp4", 900), ("Sintel.srt", 1), ("poster.jpg", 2)], run: false)
        make("Big Buck Bunny – Ultimate Edition", gb: 3.4, done: 0.62, run: false)
        make("archlinux-2024.10.01-x86_64.iso", gb: 1.1, done: 1.0, run: true)
        make("Wikipedia dump 2024-09 (de)", gb: 24.0, done: 0.07, run: false)
    }
}
#endif
