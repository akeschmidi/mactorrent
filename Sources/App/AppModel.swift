import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TorrentKit

/// App-Zustand: verwaltet alle Torrents (dauern) und deren Engines.
@MainActor
final class AppModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let torrent: TorrentInfo
        let torrentData: Data
        let rootURL: URL
        let engine: TorrentEngine
    }

    @Published var items: [Item] = []
    @Published var errorMessage: String?

    private let manifestURL: URL
    private let baseDir: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("MacTorrent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.manifestURL = dir.appendingPathComponent("manifest.json")
        self.baseDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/MacTorrent", isDirectory: true)
        try? fm.createDirectory(at: self.baseDir, withIntermediateDirectories: true)
        loadManifest()
    }

    // MARK: - Öffnen

    /// Lädt eine .torrent-Datei über NSOpenPanel.
    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.data]
        panel.message = "Torrentdateien auswählen (.torrent)"
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                try add(data: data)
            } catch {
                self.errorMessage = "Konnte \(url.lastPathComponent) nicht lesen: \(error.localizedDescription)"
            }
        }
    }

    /// Importiert ein .torrent (z. B. per Drag&Drop/URL).
    func add(data: Data) throws {
        let info = try TorrentParser.parse(data)
        let dir = baseDir.appendingPathComponent(safeName(info.name), isDirectory: true)
        let item = Item(name: info.name, torrent: info, torrentData: data,
                        rootURL: dir, engine: TorrentEngine(torrent: info, rootURL: dir))
        items.append(item)
        saveManifest()
    }

    func start(_ item: Item) {
        Task { await item.engine.start() }
    }

    func stop(_ item: Item) {
        item.engine.stop()
        saveManifest()
    }

    func recheck(_ item: Item) {
        Task { await item.engine.recheck() }
    }

    func remove(_ item: Item, deleteFiles: Bool) {
        item.engine.stop()
        if deleteFiles {
            try? FileManager.default.removeItem(at: item.rootURL)
        }
        items.removeAll { $0.id == item.id }
        saveManifest()
    }

    func openFolder(_ item: Item) {
        try? FileManager.default.createDirectory(at: item.rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(item.rootURL)
    }

    // MARK: - Persistenz

    private struct ManifestEntry: Codable {
        let name: String
        let torrentB64: String
        let root: String
    }

    private func loadManifest() {
        guard let raw = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: raw) else { return }
        for entry in entries {
            do {
                guard let data = Data(base64Encoded: entry.torrentB64) else { continue }
                let info = try TorrentParser.parse(data)
                let root = URL(fileURLWithPath: entry.root)
                let item = Item(name: info.name, torrent: info, torrentData: data,
                                rootURL: root, engine: TorrentEngine(torrent: info, rootURL: root))
                items.append(item)
            } catch {
                // kaputter Eintrag wird übersprungen
            }
        }
    }

    private func saveManifest() {
        let entries = items.map { ManifestEntry(name: $0.name,
                                                 torrentB64: $0.torrentData.base64EncodedString(),
                                                 root: $0.rootURL.path) }
        if let raw = try? JSONEncoder().encode(entries) {
            try? raw.write(to: manifestURL, options: .atomic)
        }
    }

    private func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "–")
    }
}
