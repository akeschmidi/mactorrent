import SwiftUI
import AppKit
import TorrentKit

@main
struct MacTorrentApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(Pref.menuBar) private var showMenuBar = true

    #if DEBUG
    /// Nur Debug: `--snapshot` rendert das Hauptfenster in `<Container>/tmp/snap.png` und beendet die App.
    init() { DebugSnapshot.scheduleIfRequested() }
    #endif

    var body: some Scene {
        // Ein einziges Fenster: Finder-Doppelklick auf .torrent landet per onOpenURL hier.
        Window("MacTorrent", id: "main") {
            DownloadsView(model: model)
                .frame(minWidth: 1100, minHeight: 480) // Seitenleiste + Liste + festes Detail-Panel
                .onOpenURL { url in
                    // Finder-Doppelklick (Datei) oder Klick auf einen magnet:-Link im Browser
                    url.isFileURL ? model.add(urls: [url]) : model.addInput(text: url.absoluteString)
                }
        }
        .defaultSize(width: 1100, height: 640)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false)) // schlankere Titelleiste, kein doppelter Titel
        .commands {
            CommandGroup(after: .newItem) {
                Button("Torrents hinzufügen…") { model.showAddSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Torrent-Dateien öffnen…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Torrents") {
                Button("Alle fortsetzen") { model.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Alle pausieren") { model.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Fertige entfernen") { model.confirmRemoveCompleted() }
                    .disabled(!model.items.contains { $0.engine.isValid })
            }
        }
        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        Settings { SettingsView(model: model) }
    }
}

/// Menüleisten-Symbol: bei Aktivität mit aktuellen Raten, sonst nur das Symbol.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.totalDown > 0 || model.totalUp > 0 {
            Text("↓\(Fmt.compactRate(model.totalDown)) ↑\(Fmt.compactRate(model.totalUp))")
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = model.items.filter { $0.engine.isRunning }
        Text("↓ \(Fmt.rate(model.totalDown))    ↑ \(Fmt.rate(model.totalUp))")
        if !running.isEmpty { Divider() }
        ForEach(running.prefix(8)) { item in
            Text("\(item.name) – \(Fmt.percent(item.engine.progress.fraction))")
        }
        Divider()
        Button(running.isEmpty ? "Alle fortsetzen" : "Alle pausieren") {
            running.isEmpty ? model.resumeAll() : model.pauseAll()
        }
        .disabled(model.items.isEmpty)
        Button("Fenster öffnen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("MacTorrent beenden") { NSApp.terminate(nil) }
    }
}

#if DEBUG
enum DebugSnapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func scheduleIfRequested() {
        guard requested else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("SNAPSHOT", url.path, rep.pixelsWide, rep.pixelsHigh)
            exit(0)
        }
    }
}
#endif
