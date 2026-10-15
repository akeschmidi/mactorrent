import AppKit

/// Ordner-Berechtigungen der Sandbox. Die App darf nur in Ordnern schreiben, die der Nutzer
/// im Dialog gewählt hat; der Zugriff wird als Security-Scoped Bookmark gemerkt und beim Start erneuert.
@MainActor
enum FolderAccess {
    private static let key = "folderBookmarks" // [Pfad: Bookmark]
    private static var open: [String: URL] = [:]

    /// Echter Home-Ordner (in der Sandbox zeigt NSHomeDirectory() in den Container).
    static var realHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    static func tilde(_ path: String) -> String {
        path.hasPrefix(realHome) ? "~" + path.dropFirst(realHome.count) : path
    }

    /// Beim Start: alle gespeicherten Freigaben wieder öffnen.
    static func restore() {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (path, data) in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            open[url.path] = url
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { saved[path] = fresh }
        }
        UserDefaults.standard.set(saved, forKey: key)
    }

    /// Liegt `url` in einem freigegebenen Ordner?
    static func hasAccess(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return open.keys.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    private static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        saved[url.path] = data
        UserDefaults.standard.set(saved, forKey: key)
        if open[url.path] == nil, url.startAccessingSecurityScopedResource() { open[url.path] = url }
    }

    /// Zeigt den Ordner-Dialog; die Auswahl wird sofort als Freigabe gemerkt.
    static func choose(message: String, prompt: String = String(localized: "Zugriff erlauben"), start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = start ?? URL(fileURLWithPath: realHome + "/Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Zu breite Freigaben verbieten: im ganzen Home-Ordner könnte ein Torrent z. B. ~/.ssh oder LaunchAgents erreichen.
        let p = url.standardizedFileURL.path
        if p == "/" || p == realHome || p == realHome + "/Library" {
            let alert = NSAlert()
            alert.messageText = String(localized: "Dieser Ordner ist zu umfassend")
            alert.informativeText = String(localized: "Wähle einen Unterordner, zum Beispiel „Downloads“, nicht den gesamten Home-Ordner.")
            alert.runModal()
            return nil
        }
        remember(url)
        return url
    }
}
