import SwiftUI
import AppKit
import TorrentKit

@main
struct MacTorrentApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(Pref.menuBar) private var showMenuBar = true

    var body: some Scene {
        // Ein einziges Fenster: Finder-Doppelklick auf .torrent landet per onOpenURL hier.
        Window("MacTorrent", id: "main") {
            DownloadsView(model: model)
                .frame(minWidth: 1040, minHeight: 460) // schmaler: Toolbar-Buttons rutschen ins »-Menü
                .onOpenURL { url in
                    // Finder-Doppelklick (Datei) oder Klick auf einen magnet:-Link im Browser
                    url.isFileURL ? model.add(urls: [url]) : model.addInput(text: url.absoluteString)
                }
        }
        .defaultSize(width: 1100, height: 640)
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
