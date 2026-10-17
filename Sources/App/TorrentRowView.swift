import SwiftUI
import AppKit
import TorrentKit

struct TorrentRowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: TorrentEngine
    let item: AppModel.Item

    var body: some View {
        let p = engine.progress
        let active = engine.state == .downloading || (engine.state == .done && engine.isRunning)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon.name)
                    .font(.body)
                    .foregroundStyle(icon.color)
                    .frame(width: 18)
                Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Fmt.percent(p.fraction))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 58, alignment: .trailing)
                actions
            }
            ProgressView(value: p.fraction).tint(icon.color).controlSize(.small)
            HStack(spacing: 10) {
                Text(sizeLine(p)).lineLimit(1)
                if active {
                    Label(Fmt.rate(p.downSpeed), systemImage: "arrow.down").foregroundStyle(.green)
                    Label(Fmt.rate(p.upSpeed), systemImage: "arrow.up").foregroundStyle(.blue)
                    Label("\(p.peers)", systemImage: "person.2")
                    if let eta = p.eta(totalSize: item.torrent.totalSize) {
                        Label(Fmt.eta(eta), systemImage: "clock")
                    }
                } else {
                    Text(stateLabel).lineLimit(1)
                    if p.uploadedBytes > 0 {
                        Label(Fmt.bytes(p.uploadedBytes), systemImage: "arrow.up").foregroundStyle(.blue)
                    }
                }
                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if case .failed(let reason) = engine.state {
                Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 8))
    }

    private func sizeLine(_ p: TransferProgress) -> String {
        let total = p.wantedBytes > 0 ? p.wantedBytes : item.torrent.totalSize
        return String(localized: "\(Fmt.bytes(p.verifiedBytes)) von \(Fmt.bytes(total))")
    }

    private var icon: (name: String, color: Color) {
        switch engine.state {
        case .idle: ("circle.dotted", .secondary)
        case .scanning: ("magnifyingglass.circle.fill", .orange)
        case .downloading: ("arrow.down.circle.fill", .green)
        case .done: (engine.isRunning ? "arrow.up.circle.fill" : "checkmark.circle.fill", .blue)
        case .paused: ("pause.circle.fill", .gray)
        case .failed: ("exclamationmark.triangle.fill", .red)
        }
    }

    private var stateLabel: String {
        switch engine.state {
        case .idle: String(localized: "Bereit")
        case .scanning: String(localized: "Prüft…")
        case .downloading: String(localized: "Lädt")
        case .done: engine.isRunning ? "Seedet" : String(localized: "Fertig")
        case .paused: String(localized: "Pausiert")
        case .failed: String(localized: "Fehler")
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            switch engine.state {
            case .downloading, .scanning:
                Button { model.stop(item) } label: { Image(systemName: "pause.fill") }.help("Pausieren")
            case .done:
                if engine.isRunning {
                    Button { model.stop(item) } label: { Image(systemName: "pause.fill") }.help("Seeding beenden")
                } else {
                    Button { model.start(item) } label: { Image(systemName: "play.fill") }.help("Seeding starten")
                }
            default:
                Button { model.start(item) } label: { Image(systemName: "play.fill") }.help("Fortsetzen")
            }
            Button { model.openFolder(item) } label: { Image(systemName: "folder") }
                .help("Im Finder zeigen")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}
