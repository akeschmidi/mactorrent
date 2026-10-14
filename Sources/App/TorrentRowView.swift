import SwiftUI
import AppKit
import TorrentKit

struct TorrentRowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: TorrentEngine
    let item: AppModel.Item

    var body: some View {
        let progress = engine.progress
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                stateIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(stateLabel)
                        Text("·")
                        Text("\(progress.peers) Peers")
                        if !progress.isDone {
                            Text("·")
                            Text("\(progress.fraction.formatted(.percent.precision(.fractionLength(0))))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)

            HStack(spacing: 16) {
                speedView("↓", progress.downSpeed, .green)
                speedView("↑", progress.upSpeed, .blue)
                Text("\(formatBytes(Int64(progress.downloadedBytes))) / \(formatBytes(Int64(item.torrent.totalSize)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(progress.downloadedPieces)/\(progress.totalPieces) Pieces")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if case .failed(let reason) = engine.state {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch engine.state {
        case .idle:        Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .scanning:    Image(systemName: "magnifyingglass").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
        case .done:        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
        case .paused:      Image(systemName: "pause.circle.fill").foregroundStyle(.gray)
        case .failed:      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var stateLabel: String {
        switch engine.state {
        case .idle: "Bereit"
        case .scanning: "Scannt…"
        case .downloading: "Lädt"
        case .done: "Fertig"
        case .paused: "Pausiert"
        case .failed: "Fehler"
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch engine.state {
            case .downloading, .scanning:
                Button { model.stop(item) } label: { Image(systemName: "pause.fill") }
                    .help("Pause")
            case .done:
                Button { model.recheck(item) } label: { Image(systemName: "checkmark.magnifyingglass") }
                    .help("Re-Check")
                Button { model.openFolder(item) } label: { Image(systemName: "folder") }
                    .help("Ordner öffnen")
            default:
                Button { model.start(item) } label: { Image(systemName: "play.fill") }
                    .help("Starten")
            }
            Button {
                let alert = NSAlert()
                alert.messageText = "\"\(item.name)\" entfernen?"
                alert.informativeText = "Wollen die Daten ebenfalls gelöscht werden?"
                alert.addButton(withTitle: "Daten löschen")
                alert.addButton(withTitle: "Nur aus Liste")
                alert.addButton(withTitle: "Abbrechen")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn { model.remove(item, deleteFiles: true) }
                else if response == .alertSecondButtonReturn { model.remove(item, deleteFiles: false) }
            } label: { Image(systemName: "trash") }
            .help("Entfernen")
        }
        .buttonStyle(.borderless)
    }

    private func speedView(_ icon: String, _ bps: Int64, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(icon).foregroundStyle(color)
            Text("\(formatBytes(bps))/s").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func formatBytes(_ b: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
}
