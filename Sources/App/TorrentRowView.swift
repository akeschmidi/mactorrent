import SwiftUI
import AppKit
import TorrentKit

struct TorrentRowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: TorrentEngine
    let item: AppModel.Item

    var body: some View {
        let p = engine.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon.name)
                    .font(.title2)
                    .foregroundStyle(icon.color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                actions
            }
            ProgressView(value: p.fraction).tint(icon.color)
            HStack(spacing: 14) {
                if engine.state == .downloading || (engine.state == .done && engine.isRunning) {
                    Label(Fmt.rate(p.downSpeed), systemImage: "arrow.down").foregroundStyle(.green)
                    Label(Fmt.rate(p.upSpeed), systemImage: "arrow.up").foregroundStyle(.blue)
                    Label("\(p.peers)", systemImage: "person.2")
                    if let eta = p.eta(totalSize: item.torrent.totalSize) {
                        Label(Fmt.eta(eta), systemImage: "clock")
                    }
                } else if p.uploadedBytes > 0 {
                    Label(Fmt.bytes(p.uploadedBytes), systemImage: "arrow.up").foregroundStyle(.blue)
                }
                Spacer()
                Text(Fmt.percent(p.fraction)).fontWeight(.medium)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if case .failed(let reason) = engine.state {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 5)
    }

    private func subtitle(_ p: TransferProgress) -> String {
        String(localized: "\(stateLabel) · \(Fmt.bytes(p.verifiedBytes)) von \(Fmt.bytes(p.wantedBytes > 0 ? p.wantedBytes : item.torrent.totalSize))")
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
            Button { model.openFolder(item) } label: { Image(systemName: "magnifyingglass.circle") }
                .help("Im Finder zeigen")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
    }
}
