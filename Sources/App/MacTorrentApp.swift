import SwiftUI
import AppKit
import TorrentKit

@main
struct MacTorrentApp: App {
    @StateObject private var model = AppModel()

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
        Settings { SettingsView(model: model) }
    }
}

/// Menüleiste ohne SwiftUI-`MenuBarExtra`: dessen Symbol-Button beobachtet sein eigenes Aussehen
/// und zeichnet sich deshalb dauernd neu (KVO → updateButton → setImage → neuer Snapshot).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()
    private var item: NSStatusItem?
    private var model: AppModel?
    private var openMain: () -> Void = {}
    private var title = ""
    private var observing = false

    func attach(_ model: AppModel, open: @escaping () -> Void) {
        self.model = model
        openMain = open
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyVisibility() }
            }
        }
        applyVisibility()
    }

    /// Nur aufrufen, wenn sich die angezeigte Rate geändert haben kann. Gleicher Text tut nichts.
    func refreshTitle() {
        guard let model, let button = item?.button else { return }
        let text = (model.totalDown > 0 || model.totalUp > 0)
            ? "↓\(Fmt.compactRate(model.totalDown)) ↑\(Fmt.compactRate(model.totalUp))" : ""
        guard text != title else { return }
        title = text
        button.title = text
    }

    private func applyVisibility() {
        let want = UserDefaults.standard.bool(forKey: Pref.menuBar)
        if want, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "MacTorrent")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            title = ""
            refreshTitle()
        } else if !want, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            title = ""
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let rates = NSMenuItem(title: "↓ \(Fmt.rate(model.totalDown))    ↑ \(Fmt.rate(model.totalUp))", action: nil, keyEquivalent: "")
        rates.isEnabled = false
        menu.addItem(rates)
        let running = model.items.filter { $0.engine.isRunning }
        if !running.isEmpty {
            menu.addItem(.separator())
            for item in running.prefix(8) {
                let row = NSMenuItem(title: "\(item.name) – \(Fmt.percent(item.engine.progress.fraction))", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: running.isEmpty ? "Alle fortsetzen" : "Alle pausieren",
                                 action: #selector(toggleAll), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !model.items.isEmpty
        menu.addItem(toggle)
        let open = NSMenuItem(title: "Fenster öffnen", action: #selector(openWindowItem), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "MacTorrent beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    @objc private func toggleAll() {
        guard let model else { return }
        model.items.contains { $0.engine.isRunning } ? model.pauseAll() : model.resumeAll()
    }

    @objc private func openWindowItem() { openMain() }
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
