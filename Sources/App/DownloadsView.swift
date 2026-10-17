import SwiftUI
import AppKit
import TorrentKit

enum Filter: String, CaseIterable, Identifiable {
    case all = "Alle", active = "Lädt", done = "Fertig", paused = "Pausiert"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .done: "checkmark.circle"
        case .paused: "pause.circle"
        }
    }

    func matches(_ s: EngineState) -> Bool {
        switch self {
        case .all: true
        case .active: s == .downloading || s == .scanning
        case .done: s == .done
        case .paused: s == .paused || s == .idle
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case added = "Hinzugefügt", name = "Name", progress = "Fortschritt", speed = "Geschwindigkeit", size = "Größe"
    var id: String { rawValue }
}

struct DownloadsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var filter: Filter? = .all
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var showInspector = false
    @State private var dropTargeted = false
    @AppStorage("sortKey") private var sortKey = SortKey.added.rawValue
    @AppStorage("sortAscending") private var sortAscending = true

    private var visible: [AppModel.Item] {
        let f = filter ?? .all
        let list = model.items.filter {
            f.matches($0.engine.state) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
        let key = SortKey(rawValue: sortKey) ?? .added
        guard key != .added else { return sortAscending ? list : list.reversed() }
        let sorted: [AppModel.Item]
        switch key {
        case .name: sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .progress: sorted = list.sorted { $0.engine.progress.fraction < $1.engine.progress.fraction }
        case .speed: sorted = list.sorted { $0.engine.progress.downSpeed + $0.engine.progress.upSpeed < $1.engine.progress.downSpeed + $1.engine.progress.upSpeed }
        case .size: sorted = list.sorted { $0.torrent.totalSize < $1.torrent.totalSize }
        case .added: sorted = list
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private var selectedItem: AppModel.Item? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.items.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 165, max: 220)
        } detail: {
            content
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Suchen")
        .onChange(of: selection) { _, new in if !new.isEmpty { showInspector = true } } // Details erscheinen erst bei Auswahl
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls.filter { $0.pathExtension.lowercased() == "torrent" })
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Erster Start: gleich fragen, in welchen Ordner die App schreiben darf.
        .onAppear {
            #if DEBUG
            if CommandLine.arguments.contains("--demo-select"), let first = model.items.first { selection = [first.id] }
            if DebugSnapshot.requested { return } // kein Ordner-Dialog beim Schnappschuss
            #endif
            MenuBarController.shared.attach(model) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            DispatchQueue.main.async { model.ensureBaseDir() }
        }
        .sheet(isPresented: $model.showAddSheet) { AddTorrentsSheet(model: model) }
        // ⌘V: Links oder Dateien aus der Zwischenablage direkt hinzufügen.
        .onPasteCommand(of: [.fileURL, .plainText]) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.addInput(text: url.isFileURL ? url.path : url.absoluteString) } }
                    }
                } else {
                    _ = p.loadObject(ofClass: String.self) { str, _ in
                        if let str { Task { @MainActor in model.addInput(text: str) } }
                    }
                }
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.errorMessage != nil },
                                                set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    // MARK: Seitenleiste

    private var sidebar: some View {
        List(Filter.allCases, selection: $filter) { f in
            Label(LocalizedStringKey(f.rawValue), systemImage: f.icon)
                .badge(model.items.filter { f.matches($0.engine.state) }.count)
                .tag(f)
        }
        .safeAreaInset(edge: .bottom) { statusPanel }
    }

    // MARK: Statusbereich unten links

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Label(Fmt.rate(model.totalDown), systemImage: "arrow.down").foregroundStyle(.green)
                Label(Fmt.rate(model.totalUp), systemImage: "arrow.up").foregroundStyle(.blue)
            }
            .font(.callout.monospacedDigit())
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                dhtRow
                protectionRow
                if UserDefaults.standard.bool(forKey: Pref.anonymousMode) {
                    statusRow("eye.slash", .secondary, String(localized: "Anonymer Modus"))
                }
                if model.portStatus.contains("offen") {
                    statusRow("network", .green, String(localized: "Port offen")).help(model.portStatus)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Idealbreite der Statuszeilen darf die Spalten-Obergrenze nicht überstimmen.
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Eine Statuszeile: Symbol in fester Breite, damit alle Texte untereinander bündig stehen.
    private func statusRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var protectionRow: some View {
        let (icon, color, text, help): (String, Color, String, String)
        switch model.protection {
        case .none: (icon, color, text, help) = ("shield.slash", .gray, String(localized: "Kein VPN-Schutz"), String(localized: "Deine IP ist für Peers sichtbar. Unter Einstellungen → Privatsphäre kannst du eine VPN-Schnittstelle erzwingen."))
        case .bound(let n): (icon, color, text, help) = ("lock.shield.fill", .green, String(localized: "Nur über \(n)"), String(localized: "Alle Verbindungen laufen ausschließlich über \(n)."))
        case .blocked(let n): (icon, color, text, help) = ("exclamationmark.shield.fill", .red, String(localized: "\(n) getrennt – gestoppt"), String(localized: "Die erzwungene Schnittstelle ist nicht verbunden; es wird nichts gesendet."))
        }
        return statusRow(icon, color, text).help(help)
    }

    private var dhtRow: some View {
        let on = UserDefaults.standard.bool(forKey: Pref.dhtEnabled)
        let color: Color = !on ? .gray : model.dhtNodes >= 50 ? .green : .orange
        let text = on ? String(localized: "DHT: \(model.dhtNodes) Knoten") : String(localized: "DHT aus")
        let help = on ? String(localized: "Verifizierte DHT-Knoten. Ab ca. 50 läuft die Peer-Suche ohne Tracker zuverlässig.")
                      : String(localized: "In den Einstellungen unter Netzwerk einschalten")
        return statusRow("point.3.connected.trianglepath.dotted", color, text).help(help)
    }

    // MARK: Liste

    private var content: some View {
        // Eigenes Seitenpanel statt `.inspector`: Der SwiftUI-Inspector vergrößert beim Öffnen das Fenster.
        // Hier bleibt das Fenster gleich groß, die Liste wird schmaler.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Divider()
                // Der leere Zustand füllt die Spalte, sonst zentriert die VStack alles und die Leiste rutscht in die Mitte.
                list.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 480, maxHeight: .infinity, alignment: .top)
            if showInspector {
                Divider()
                detailPanel
                    .frame(width: Self.detailWidth)
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .background(.background.secondary)
                    .transition(.identity)
            }
        }
    }

    /// Feste Breite des Detail-Panels (Auswahl ändert die Fenstergröße nie).
    private static let detailWidth: CGFloat = 400

    @ViewBuilder
    private var detailPanel: some View {
        if let item = selectedItem {
            TorrentDetailView(model: model, item: item, engine: item.engine).id(item.id)
        } else {
            ContentUnavailableView("Kein Torrent gewählt", systemImage: "sidebar.right")
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.items.isEmpty && model.pending.isEmpty {
            emptyState
        } else if visible.isEmpty && model.pending.isEmpty {
            ContentUnavailableView(search.isEmpty ? "Keine Torrents in „\(String(localized: String.LocalizationValue((filter ?? .all).rawValue)))“" : "Keine Treffer",
                                   systemImage: "magnifyingglass")
        } else {
            List(selection: $selection) {
                if (filter ?? .all) == .all || filter == .active {
                    ForEach(model.pending) { p in pendingRow(p) }
                }
                ForEach(visible) { item in
                    TorrentRowView(model: model, engine: item.engine, item: item)
                        .tag(item.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                for item in items(ids) { model.openFolder(item) }
            }
            .onDeleteCommand { model.confirmRemove(items(selection)) }
            .onKeyPress(.space) {
                guard !selection.isEmpty else { return .ignored }
                for item in items(selection) { model.toggle(item) }
                return .handled
            }
        }
    }

    private func pendingRow(_ p: AppModel.Pending) -> some View {
        HStack(spacing: 10) {
            if p.error == nil { ProgressView().controlSize(.small).frame(width: 28) }
            else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title2).frame(width: 28) }
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(p.error ?? "Metadaten: \(p.resolver.status)").font(.caption).foregroundStyle(p.error == nil ? Color.secondary : Color.red)
            }
            Spacer()
            Button { model.dismissPending(p.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Abbrechen")
        }
        .padding(.vertical, 5)
    }

    private func items(_ ids: Set<UUID>) -> [AppModel.Item] {
        model.items.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        let sel = items(ids)
        if !sel.isEmpty {
            Button("Fortsetzen", systemImage: "play.fill") { sel.forEach { model.start($0) } }
            Button("Pausieren", systemImage: "pause.fill") { sel.forEach { model.stop($0) } }
            Divider()
            Button("Im Finder zeigen", systemImage: "folder") { sel.forEach { model.openFolder($0) } }
            Button("Erneut prüfen", systemImage: "checkmark.arrow.trianglehead.counterclockwise") {
                sel.forEach { model.recheck($0) }
            }
            Button("Info-Hash kopieren", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sel.map(\.torrent.infoHashHex).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Entfernen…", systemImage: "trash", role: .destructive) { model.confirmRemove(sel) }
        }
    }

    // MARK: Obere Leiste
    // Eigene Leiste statt .toolbar: mit Inspector klappt SwiftUI die Toolbar sonst ins »-Menü, auch bei viel Platz.

    private var topBar: some View {
        let anyRunning = model.items.contains { $0.engine.isRunning }
        return HStack(spacing: 8) {
            Button { model.showAddSheet = true } label: { Label("Hinzufügen", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
                .help("Links und Dateien hinzufügen (⌘N)")
            Button { anyRunning ? model.pauseAll() : model.resumeAll() } label: {
                Label(anyRunning ? "Alle pausieren" : "Alle fortsetzen", systemImage: anyRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .help(anyRunning ? "Alle pausieren (⌥⌘P)" : "Alle fortsetzen (⌥⌘R)")
            .disabled(model.items.isEmpty)
            Button { model.confirmRemoveCompleted() } label: {
                Label("Fertige entfernen", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .help("Alle fertigen Torrents aus der Liste entfernen")
            .disabled(!model.items.contains { $0.engine.isValid })
            Spacer()
            Menu {
                Picker("Sortieren nach", selection: $sortKey) {
                    ForEach(SortKey.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Aufsteigend", isOn: $sortAscending)
            } label: {
                Label("Sortieren", systemImage: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)
            .help("Liste sortieren")
            SettingsLink { Label("Einstellungen", systemImage: "gearshape") }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .help("Einstellungen (⌘,)")
            Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .help("Details ein-/ausblenden")
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Leerer Zustand

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Noch keine Torrents", systemImage: "arrow.down.circle")
        } description: {
            Text("Ziehe .torrent-Dateien in das Fenster, füge Magnet-Links mit ⌘V ein oder nutze „Hinzufügen“.")
                .frame(maxWidth: 380)
        } actions: {
            Button("Torrents hinzufügen…") { model.showAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

