import SwiftUI
import AppKit
import TorrentKit

struct DownloadsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("MacTorrent")
                    .font(.title2.bold())
                if let err = model.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Button("×") { model.errorMessage = nil }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.openPanel()
                } label: {
                    Label("Torrent öffnen…", systemImage: "plus.circle")
                }
                .keyboardShortcut("o", modifiers: .command)
                Button {
                    // Re-Check alle
                    for item in model.items where item.engine.state != .scanning {
                        Task { await item.engine.recheck() }
                    }
                } label: {
                    Label("Re-Check", systemImage: "checkmark.magnifyingglass")
                }
                .disabled(model.items.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if model.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.items) { item in
                        TorrentRowView(model: model, engine: item.engine, item: item)
                    }
                    .onDelete { indexSet in
                        for i in indexSet { model.remove(model.items[i], deleteFiles: false) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Noch keine Torrents")
                .font(.headline)
            Text("Wähle eine .torrent-Datei aus, um den Download zu starten.\nOder ziehe sie auf das App-Fenster.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Torrent öffnen…") { model.openPanel() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
