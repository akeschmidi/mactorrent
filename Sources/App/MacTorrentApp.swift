import SwiftUI
import AppKit
import TorrentKit

@main
struct MacTorrentApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            DownloadsView(model: model)
                .frame(minWidth: 720, minHeight: 420)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Torrent öffnen…") { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
