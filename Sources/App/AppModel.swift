import SwiftUI
import AppKit
import UserNotifications
import TorrentKit

/// App-Zustand: verwaltet alle Torrents (dauern) und deren Engines.
@MainActor
final class AppModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let torrent: TorrentInfo
        /// Rohdatei auf der Platte. Der Inhalt bleibt nicht im RAM (Manifest liest sie beim Speichern).
        let torrentFile: URL
        let engine: TorrentEngine
        /// Aktueller Ordner (ändert sich, wenn der Download aus „Unfertig“ verschoben wird).
        @MainActor var rootURL: URL { engine.rootURL }
    }

    /// Magnet-Link, dessen Metadaten noch geholt werden.
    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let resolver: MagnetResolver
        var error: String?
    }

    @Published var items: [Item] = []
    @Published var errorMessage: String?
    @Published var pending: [Pending] = []
    @Published var showAddSheet = false
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    /// Sekundentakt: die Listen filtern nach Engine-Zustand und müssen neu rechnen.
    @Published private(set) var tick = 0
    @Published private(set) var totalDown: Int64 = 0
    @Published private(set) var totalUp: Int64 = 0
    /// Verifizierte DHT-Knoten (Anzeige in der Seitenleiste).
    @Published private(set) var dhtNodes = 0
    let dht: DHT
    /// Ergebnis der automatischen Router-Freigabe für die Anzeige.
    @Published private(set) var portStatus = String(localized: "Automatische Freigabe: inaktiv")
    private var mappedPort = 0
    private let mapper = PortMapper.shared
    /// Zustand des VPN-Schutzes für die Seitenleiste.
    enum Protection: Equatable { case none, bound(String), blocked(String) }
    @Published private(set) var protection = Protection.none
    private var pausedByGuard = Set<UUID>()
    private var appliedPolicy = ""

    private let manifestURL: URL
    private let stateURL: URL
    private let torrentsDir: URL
    /// Rohbytes, falls die .torrent-Datei nicht auf die Platte kam. Sonst leer, damit sie nicht im RAM bleiben.
    private var unsavedTorrents: [String: Data] = [:]
    private var wasActive = Set<UUID>()
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var rateTimer: Timer?

    init() {
        Pref.registerDefaults()
        FolderAccess.restore()
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("MacTorrent", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.manifestURL = dir.appendingPathComponent("manifest.json")
        self.stateURL = dir.appendingPathComponent("state.json")
        let torrents = dir.appendingPathComponent("torrents", isDirectory: true)
        try? fm.createDirectory(at: torrents, withIntermediateDirectories: true)
        self.torrentsDir = torrents
        self.dht = DHT(storage: dir.appendingPathComponent("dht.json"))
        NetworkPolicy.shared.onChange = { [weak self] in
            Task { @MainActor in self?.policyChanged() }
        }
        loadManifest()
        #if DEBUG
        if CommandLine.arguments.contains("--demo") { loadDemo() }
        #endif
        applySettings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveState(); self?.dht.stop()
                // Router-Eintrag zurückgeben, kurz warten (Beenden darf nicht hängen).
                if let m = self?.mapper {
                    let done = DispatchSemaphore(value: 0)
                    Task.detached { await m.unmap(); done.signal() }
                    _ = done.wait(timeout: .now() + 1.5)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.secondTick() }
        }
        rateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishRates() }
        }
        if UserDefaults.standard.bool(forKey: Pref.notify) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - Einstellungen

    /// Gewählter Download-Ordner; nil, solange der Nutzer noch keinen freigegeben hat.
    private var baseDir: URL? {
        let path = UserDefaults.standard.string(forKey: Pref.downloadPath) ?? ""
        let url = path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        return url.flatMap { FolderAccess.hasAccess($0) ? $0 : nil }
    }

    /// Fragt per Dialog nach dem Download-Ordner, falls noch keiner freigegeben ist.
    @discardableResult
    func ensureBaseDir() -> URL? {
        if let b = baseDir { return b }
        guard let url = FolderAccess.choose(message: String(localized: "Wähle den Ordner, in dem MacTorrent Downloads speichern darf.")) else {
            report(String(localized: "Ohne freigegebenen Ordner kann MacTorrent nichts speichern. Wähle einen unter Einstellungen → Allgemein."))
            return nil
        }
        UserDefaults.standard.set(url.path, forKey: Pref.downloadPath)
        return url
    }

    /// Ordner für unfertige Downloads, nil = direkt im Zielordner.
    private var incompleteDir: URL? {
        let path = UserDefaults.standard.string(forKey: Pref.incompletePath) ?? ""
        let url = path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        return url.flatMap { FolderAccess.hasAccess($0) ? $0 : nil }
    }

    var defaultDestination: URL? { baseDir }

    /// Schiebt die Einstellungen in alle Engines (Limits wirken sofort).
    private func applySettings() {
        let d = UserDefaults.standard
        let policy = NetworkPolicy.shared
        let iface = d.string(forKey: Pref.boundInterface) ?? "", anon = d.bool(forKey: Pref.anonymousMode)
        policy.interfaceName = iface
        policy.anonymous = anon
        policy.allowLocalTrackers = d.bool(forKey: Pref.allowLocalTrackers)
        // Schnittstelle oder Modus geändert: laufende Verbindungen hängen noch an den alten Regeln → neu starten.
        let port = d.integer(forKey: Pref.listenPort)
        let key = "\(iface)|\(anon)|\(port)"
        if appliedPolicy != key {
            let first = appliedPolicy.isEmpty
            appliedPolicy = key
            if !first { restartRunning() }
        }
        let useDHT = d.bool(forKey: Pref.dhtEnabled)
        if useDHT && !dht.isRunning { dht.start() } else if !useDHT && dht.isRunning { dht.stop() }
        for item in items {
            item.engine.dht = useDHT ? dht : nil
            item.engine.preferredPort = port
            item.engine.downLimit = Int64(max(0, d.integer(forKey: Pref.downLimitKB))) * 1024
            item.engine.upLimit = Int64(max(0, d.integer(forKey: Pref.upLimitKB))) * 1024
            item.engine.maxPeers = max(5, d.integer(forKey: Pref.maxPeers))
            item.engine.allowPublicTrackers = d.bool(forKey: Pref.publicTrackers)
        }
        if !d.bool(forKey: Pref.dockBadge) { NSApp?.dockTile.badgeLabel = nil }
    }

    // MARK: - VPN-Schutz

    private func restartRunning() {
        let running = items.filter { $0.engine.isRunning }
        for i in running { i.engine.stop() }
        if dht.isRunning { dht.stop() }
        Task { @MainActor in
            applySettings() // startet DHT neu
            for i in running { start(i) }
        }
    }

    /// Schnittstelle verschwunden → alles stoppen (Kill-Switch); zurück → vorher Laufendes fortsetzen.
    private func policyChanged() {
        let policy = NetworkPolicy.shared
        let name = policy.interfaceName
        if policy.isBlocked {
            protection = .blocked(name ?? "")
            for i in items where i.engine.isRunning { pausedByGuard.insert(i.id); i.engine.stop() }
            if dht.isRunning { dht.stop() }
        } else {
            protection = name.map { .bound($0) } ?? .none
            if !pausedByGuard.isEmpty {
                let resume = items.filter { pausedByGuard.contains($0.id) }
                pausedByGuard = []
                applySettings() // DHT wieder an die Schnittstelle binden
                for i in resume { start(i) }
            }
        }
    }

    // MARK: - Sekundentakt: Summen, Dock, Fertig-Meldung, App-Nap

    /// Seitenleiste und Menüleiste: dieselbe Rate wie in der Zeile, viermal pro Sekunde.
    private func publishRates() {
        var down: Int64 = 0, up: Int64 = 0
        for item in items where item.engine.isRunning {
            down += item.engine.progress.downSpeed
            up += item.engine.progress.upSpeed
        }
        if down != totalDown { totalDown = down }
        if up != totalUp { totalUp = up }
    }

    private func secondTick() {
        tick += 1
        var active = 0, seeding = 0
        dhtNodes = dht.nodeCount
        let name = NetworkPolicy.shared.interfaceName
        let p: Protection = name == nil ? .none : (NetworkPolicy.shared.isBlocked ? .blocked(name!) : .bound(name!))
        if p != protection { protection = p }
        for item in items {
            let e = item.engine
            switch e.state {
            case .downloading, .scanning:
                active += 1
                wasActive.insert(item.id)
            case .done:
                if e.isRunning { seeding += 1 }
                if wasActive.remove(item.id) != nil {
                    notifyDone(item)
                    saveState()
                }
            default: break
            }
        }
        let badge = UserDefaults.standard.bool(forKey: Pref.dockBadge) && active > 0
        NSApp?.dockTile.badgeLabel = badge ? "\(active)" : nil
        // Ohne das drosselt macOS (App Nap) Timer und Netzwerk, sobald das Fenster verdeckt ist.
        if active + seeding > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Torrent-Download")
        } else if active + seeding == 0, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        updatePortMapping()
        if tick % 10 == 0 { saveState() }
    }

    /// Gibt den Listen-Port am Router frei, solange ein Torrent lauscht – nur im LAN, nicht anonym, ohne erzwungenes VPN.
    private func updatePortMapping() {
        let d = UserDefaults.standard
        let allowed = d.bool(forKey: Pref.portMapping) && !d.bool(forKey: Pref.anonymousMode)
            && (d.string(forKey: Pref.boundInterface) ?? "").isEmpty
        let port = allowed ? (items.map(\.engine.listenPort).first { $0 > 0 } ?? 0) : 0
        guard port != mappedPort else { return }
        mappedPort = port
        if port == 0 {
            portStatus = allowed ? String(localized: "Automatische Freigabe: wartet auf einen laufenden Torrent") : String(localized: "Automatische Freigabe: inaktiv (aus, anonymer Modus oder VPN-Schnittstelle)")
            Task { await mapper.unmap() }
            return
        }
        portStatus = String(localized: "Freigabe für Port \(port) wird eingerichtet…")
        Task {
            let m = await mapper.map(port: port)
            guard mappedPort == port else { return }
            portStatus = m.map { mp in
                mp.externalIP.map { String(localized: "Port \(mp.port) offen via \(mp.method) · externe IP \($0)") }
                    ?? String(localized: "Port \(mp.port) offen via \(mp.method)")
            } ?? String(localized: "Keine automatische Freigabe möglich – Port \(port) ggf. im Router weiterleiten")
        }
    }

    private func notifyDone(_ item: Item) {
        guard UserDefaults.standard.bool(forKey: Pref.notify) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Download fertig")
        content.body = item.name
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
    }

    // MARK: - Öffnen

    /// Lädt .torrent-Dateien über NSOpenPanel.
    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.data]
        panel.message = String(localized: "Torrentdateien auswählen (.torrent)")
        panel.prompt = String(localized: "Hinzufügen")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        add(urls: panel.urls)
    }

    /// Datei-URLs aus Drag&Drop, Finder-Doppelklick oder Öffnen-Dialog.
    func add(urls: [URL], destination: URL? = nil) {
        for url in urls where url.isFileURL {
            do {
                try add(data: try Data(contentsOf: url), destination: destination)
            } catch {
                report("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Ein Eingang für alles: Text mit Magnet-Links, .torrent-URLs und Dateipfaden (je Zeile),
    /// dazu beliebig viele Dateien. Fehler werden gesammelt statt einzeln angezeigt.
    func addInput(text: String, files: [URL] = [], destination: URL? = nil) {
        var fileURLs = files
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            let parts = (l.hasPrefix("magnet:") || l.hasPrefix("http")) ? l.split(separator: " ").map(String.init) : [l]
            for part in parts {
                if let magnet = MagnetLink(part) {
                    addMagnet(magnet, destination: destination)
                } else if let url = URL(string: part), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    addRemote(url, destination: destination)
                } else if part.hasPrefix("file://"), let url = URL(string: part) {
                    fileURLs.append(url)
                } else if part.hasPrefix("/") || part.hasPrefix("~") {
                    fileURLs.append(URL(fileURLWithPath: (part as NSString).expandingTildeInPath))
                } else {
                    report(String(localized: "Nicht erkannt: \(part.prefix(80))"))
                }
            }
        }
        add(urls: fileURLs, destination: destination)
    }

    private func addRemote(_ url: URL, destination: URL?) {
        Task {
            do {
                // Eigener Client: kein User-Agent, und der VPN-Schutz gilt auch hier.
                try add(data: try await HTTPClient.get(url, timeout: 30), destination: destination)
            } catch {
                report("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func addMagnet(_ link: MagnetLink, destination: URL?) {
        guard !items.contains(where: { $0.torrent.infoHash == link.infoHash }),
              !pending.contains(where: { $0.resolver.infoHash == link.infoHash }) else {
            report(String(localized: "„\(link.name ?? link.infoHashHex)“ ist bereits in der Liste."))
            return
        }
        let p = Pending(title: link.name ?? link.infoHashHex, resolver: MagnetResolver(link: link, extraTrackers: UserDefaults.standard.bool(forKey: Pref.publicTrackers) ? nil : [],
                                                           dht: UserDefaults.standard.bool(forKey: Pref.dhtEnabled) ? dht : nil))
        pending.append(p)
        pendingTasks[p.id] = Task {
            do {
                let data = try await p.resolver.resolve()
                try add(data: data, destination: destination)
                dismissPending(p.id)
            } catch is CancellationError {
                dismissPending(p.id)
            } catch {
                if let i = pending.firstIndex(where: { $0.id == p.id }) {
                    pending[i].error = error.localizedDescription
                }
            }
        }
    }

    func dismissPending(_ id: UUID) {
        pendingTasks[id]?.cancel()
        pendingTasks[id] = nil
        pending.removeAll { $0.id == id }
    }

    func report(_ message: String) {
        errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
    }

    func add(data: Data, destination: URL? = nil) throws {
        let info = try TorrentParser.parse(data)
        if items.contains(where: { $0.torrent.infoHash == info.infoHash }) {
            report(String(localized: "„\(info.name)“ ist bereits in der Liste."))
            return
        }
        // Mit Unfertig-Ordner lädt der Torrent dort und zieht nach dem Download in den Zielordner.
        guard let base = destination ?? ensureBaseDir() else { return }
        guard var finalDir = resolveExisting(base.appendingPathComponent(safeName(info.name), isDirectory: true), name: info.name) else { return }
        var workDir = incompleteDir.map { $0.appendingPathComponent(safeName(info.name), isDirectory: true) } ?? finalDir
        if workDir != finalDir {
            guard let w = resolveExisting(workDir, name: info.name) else { return }
            workDir = w
        } else {
            workDir = finalDir
        }
        finalDir = incompleteDir == nil ? workDir : finalDir
        let item = makeItem(info: info, data: data, root: workDir, final: workDir == finalDir ? nil : finalDir)
        items.append(item)
        saveManifest()
        start(item)
    }

    /// Existiert der Zielordner schon (nicht von der App angelegt), überschreibt ein fremder Torrent sonst
    /// vorhandene Dateien, deren Inhalt er mitliefert. Darum fragen: neuer Ordner (Standard) / vorhandenen nutzen.
    private func resolveExisting(_ dir: URL, name: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return dir }
        let alert = NSAlert()
        alert.messageText = String(localized: "„\(dir.lastPathComponent)“ existiert bereits")
        alert.informativeText = String(localized: "In \(FolderAccess.tilde(dir.deletingLastPathComponent().path)) gibt es schon einen Ordner mit diesem Namen. Vorhandene Dateien, die zum Torrent passen, würden überschrieben.")
        alert.addButton(withTitle: String(localized: "Neuen Ordner anlegen"))
        alert.addButton(withTitle: String(localized: "Vorhandenen verwenden"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            var n = 2
            var candidate = dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent) \(n)", isDirectory: true)
            while fm.fileExists(atPath: candidate.path) {
                n += 1
                candidate = dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent) \(n)", isDirectory: true)
            }
            return candidate
        case .alertSecondButtonReturn: return dir
        default: return nil
        }
    }

    private func makeItem(info: TorrentInfo, data: Data, root: URL, final: URL?) -> Item {
        let file = torrentsDir.appendingPathComponent(info.infoHashHex + ".torrent")
        if FileManager.default.fileExists(atPath: file.path) {
            unsavedTorrents[info.infoHashHex] = nil
        } else if (try? data.write(to: file, options: .atomic)) != nil {
            unsavedTorrents[info.infoHashHex] = nil
        } else {
            unsavedTorrents[info.infoHashHex] = data
        }
        let engine = TorrentEngine(torrent: info, rootURL: root)
        engine.completedDir = final
        engine.onRelocated = { [weak self] _ in self?.saveManifest() }
        return Item(name: info.name, torrent: info, torrentFile: file, engine: engine)
    }

    // MARK: - Steuerung

    func start(_ item: Item) {
        if NetworkPolicy.shared.isBlocked {
            let n = NetworkPolicy.shared.interfaceName ?? ""
            report(String(localized: "VPN-Schutz: „\(n)“ ist nicht verbunden. Es wird nichts gesendet."))
            return
        }
        // Nach Neuinstallation oder verschobenem Ordner fehlt ggf. die Freigabe: erneut fragen.
        if !FolderAccess.hasAccess(item.rootURL),
           FolderAccess.choose(message: String(localized: "Zugriff auf den Ordner von „\(item.name)“ erlauben."),
                               start: item.rootURL.deletingLastPathComponent()) == nil
            || !FolderAccess.hasAccess(item.rootURL) {
            report(String(localized: "Kein Zugriff auf \(FolderAccess.tilde(item.rootURL.path)). Wähle den Ordner oder einen übergeordneten Ordner."))
            return
        }
        applySettings()
        Task { await item.engine.start(); saveState() }
    }

    func stop(_ item: Item) {
        item.engine.stop()
        wasActive.remove(item.id)
        saveState()
    }

    func toggle(_ item: Item) {
        switch item.engine.state {
        case .downloading, .scanning: stop(item)
        case .done: item.engine.isRunning ? stop(item) : start(item)
        default: start(item)
        }
    }

    func pauseAll() { items.forEach { stop($0) } }

    func resumeAll() {
        for item in items where !item.engine.isRunning { start(item) }
    }

    func recheck(_ item: Item) {
        Task { await item.engine.recheck(); saveState() }
    }

    func remove(_ list: [Item], deleteFiles: Bool) {
        guard !list.isEmpty else { return }
        for item in list {
            item.engine.stop()
            if deleteFiles, isOwnFolder(item.rootURL) {
                // In den Papierkorb statt endgültig löschen.
                try? FileManager.default.trashItem(at: item.rootURL, resultingItemURL: nil)
            }
            wasActive.remove(item.id)
        }
        let ids = Set(list.map(\.id))
        items.removeAll { ids.contains($0.id) }
        saveManifest()
        saveState()
        for item in list {
            unsavedTorrents[item.torrent.infoHashHex] = nil
            try? FileManager.default.removeItem(at: item.torrentFile)
        }
    }

    /// Nachfrage vor dem Entfernen (Kontextmenü, Entf-Taste, „Fertige entfernen“). Eine Nachfrage für die ganze Auswahl.
    func confirmRemove(_ list: [Item]) {
        guard !list.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = list.count == 1
            ? String(localized: "„\(list[0].name)“ entfernen?")
            : String(localized: "\(list.count) Torrents entfernen?")
        alert.informativeText = String(localized: "Die heruntergeladenen Dateien können in den Papierkorb gelegt werden.")
        alert.addButton(withTitle: String(localized: "Nur aus Liste"))
        alert.addButton(withTitle: String(localized: "Dateien in den Papierkorb"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: remove(list, deleteFiles: false)
        case .alertSecondButtonReturn: remove(list, deleteFiles: true)
        default: break
        }
    }

    /// Alle fertigen Torrents (auch pausierte Seeder) in einem Schritt aus der Liste.
    func confirmRemoveCompleted() {
        confirmRemove(items.filter { $0.engine.isValid })
    }

    func openFolder(_ item: Item) {
        try? FileManager.default.createDirectory(at: item.rootURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([item.rootURL])
    }

    // MARK: - Persistenz

    private struct ManifestEntry: Codable {
        let name: String
        let torrentB64: String
        let root: String
        let final: String?
    }

    /// Laufender Stand je Torrent (klein, wird oft geschrieben): Piece-Bitfield + ob aktiv.
    private struct SavedState: Codable {
        var bitfield: Data
        var active: Bool
        var filesWanted: [Bool]?   // nil = alle (ältere Stände)
    }

    private func loadManifest() {
        guard let raw = try? Data(contentsOf: manifestURL),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: raw) else { return }
        let states = (try? JSONDecoder().decode([String: SavedState].self,
                                                 from: Data(contentsOf: stateURL))) ?? [:]
        let resume = UserDefaults.standard.bool(forKey: Pref.autoResume)
        for entry in entries {
            guard let data = Data(base64Encoded: entry.torrentB64),
                  let info = try? TorrentParser.parse(data) else { continue } // kaputter Eintrag wird übersprungen
            let item = makeItem(info: info, data: data, root: URL(fileURLWithPath: entry.root),
                                final: entry.final.map { URL(fileURLWithPath: $0) })
            items.append(item)
            if let s = states[info.infoHashHex] {
                if let w = s.filesWanted { item.engine.setFilesWanted(w) }
                item.engine.restoreBitfield(s.bitfield)
                if s.active && resume { Task { @MainActor in self.start(item) } }
            }
        }
    }

    private func saveManifest() {
        let previous = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([ManifestEntry].self, from: $0) } ?? []
        let entries = items.map { item in
            let fresh = unsavedTorrents[item.torrent.infoHashHex] ?? (try? Data(contentsOf: item.torrentFile))
            let b64 = fresh?.base64EncodedString()
                ?? previous.first { $0.name == item.name && $0.root == item.rootURL.path }?.torrentB64
                ?? ""
            return ManifestEntry(name: item.name, torrentB64: b64, root: item.rootURL.path, final: item.engine.completedDir?.path)
        }
        if let raw = try? JSONEncoder().encode(entries) {
            try? raw.write(to: manifestURL, options: .atomic)
        }
    }

    func saveState() {
        var states: [String: SavedState] = [:]
        for item in items {
            // isRunning gilt sofort nach Pause/Start; `state` hinkt dem Hintergrund-Kern kurz hinterher.
            let active = item.engine.isRunning
            states[item.torrent.infoHashHex] = SavedState(bitfield: item.engine.pieceBitfield(), active: active, filesWanted: item.engine.filesWanted)
        }
        if let raw = try? JSONEncoder().encode(states) {
            try? raw.write(to: stateURL, options: .atomic)
        }
    }

    private func safeName(_ s: String) -> String { TorrentParser.sanitizedName(s) }

    /// Nur Ordner löschen, die unter einem freigegebenen Ordner liegen und nicht der Ordner selbst sind
    /// (nie ein Download-/Unfertig-Ordner als Ganzes, auch wenn ein Manifest-Eintrag darauf zeigt).
    private func isOwnFolder(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let roots = [baseDir, incompleteDir].compactMap { $0?.standardizedFileURL.path }
        return FolderAccess.hasAccess(url) && !roots.contains(p) && p != FolderAccess.realHome && p != "/"
    }
}
