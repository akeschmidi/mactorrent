import SwiftUI
import TorrentKit

/// Inspector für den gewählten Torrent: Übersicht, Dateien, Log.
struct TorrentDetailView: View {
    @ObservedObject var model: AppModel
    let item: AppModel.Item
    @ObservedObject var engine: TorrentEngine
    @State private var tab = Tab.overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Übersicht", files = "Dateien", peers = "Peers", trackers = "Tracker", log = "Log"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(10)
            Divider()
            switch tab {
            case .overview: overview
            case .files: files
            case .peers: peers
            case .trackers: trackers
            case .log: log
            }
        }
    }

    // MARK: Übersicht

    private var overview: some View {
        let p = engine.progress
        let t = item.torrent
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.name).font(.headline).textSelection(.enabled).detailWidth()
                PieceMap(engine: engine)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Fortschritt", Fmt.percent(p.fraction))
                    row("Größe", Fmt.bytes(t.totalSize))
                    if p.wantedBytes > 0 && p.wantedBytes != t.totalSize { row("Ausgewählt", Fmt.bytes(p.wantedBytes)) }
                    row("Geladen", Fmt.bytes(p.verifiedBytes))
                    row("Hochgeladen", Fmt.bytes(p.uploadedBytes))
                    row("Verhältnis", ratio(p))
                    row("Download", Fmt.rate(p.downSpeed))
                    row("Upload", Fmt.rate(p.upSpeed))
                    row("Restzeit", Fmt.eta(p.eta(totalSize: t.totalSize)))
                    row("Peers", "\(p.peers)")
                    if !t.isPrivate { row("DHT-Peers", "\(p.dhtPeers)") }
                    row("Pieces", "\(p.downloadedPieces) / \(p.totalPieces) × \(Fmt.bytes(Int64(t.pieceLength)))")
                    row("Dateien", "\(t.numberOfFiles)")
                    row("Tracker", "\(t.trackerURLs.count)")
                    row("Privat", t.isPrivate ? String(localized: "Ja") : String(localized: "Nein"))
                    if let c = t.created { row("Erstellt", c.formatted(date: .abbreviated, time: .omitted)) }
                    row("Ort", FolderAccess.tilde(item.rootURL.path))
                    row("Info-Hash", t.infoHashHex)
                }
                .font(.callout)
            }
            .padding(12)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).monospacedDigit().lineLimit(2).truncationMode(.middle).detailWidth()
        }
    }

    private func ratio(_ p: TransferProgress) -> String {
        p.verifiedBytes > 0 ? String(format: "%.2f", Double(p.uploadedBytes) / Double(p.verifiedBytes)) : "–"
    }

    // MARK: Dateien

    /// Mit Haken: nur gewählte Dateien werden geladen. Abgewählte Dateien, die Pieces mit gewählten teilen,
    /// können an den Rändern trotzdem teilweise auf der Platte landen.
    private var files: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let progress = engine.fileProgress()
            VStack(spacing: 0) {
                HStack {
                    Button("Alle") { setAll(true) }
                    Button("Keine") { setAll(false) }
                    Spacer()
                    Text("\(engine.filesWanted.filter { $0 }.count) von \(engine.filesWanted.count) gewählt")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                List(Array(item.torrent.entries.enumerated()), id: \.element.id) { index, e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Toggle(isOn: wantedBinding(index)) {
                                Text(e.path).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Fmt.bytes(Int64(e.length))).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress[e.id] ?? 0).controlSize(.small)
                            .opacity(engine.filesWanted[index] ? 1 : 0.35)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    private func wantedBinding(_ i: Int) -> Binding<Bool> {
        Binding(get: { i < engine.filesWanted.count && engine.filesWanted[i] },
                set: { v in
                    var w = engine.filesWanted
                    w[i] = v
                    engine.setFilesWanted(w)
                    model.saveState()
                })
    }

    private func setAll(_ v: Bool) {
        engine.setFilesWanted(Array(repeating: v, count: engine.filesWanted.count))
        model.saveState()
    }

    // MARK: Peers

    private var peers: some View {
        Group {
            if engine.peerList.isEmpty {
                ContentUnavailableView("Keine Verbindungen", systemImage: "person.2.slash")
            } else {
                List(engine.peerList) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: p.incoming ? "arrow.down.left" : "arrow.up.right")
                                .foregroundStyle(.secondary).help(p.incoming ? "Eingehend" : "Ausgehend")
                            Text(p.address).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            Text(p.client).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 10) {
                            Label(Fmt.rate(p.downRate), systemImage: "arrow.down").foregroundStyle(p.downRate > 0 ? .green : .secondary)
                            Label(Fmt.rate(p.upRate), systemImage: "arrow.up").foregroundStyle(p.upRate > 0 ? .blue : .secondary)
                            Spacer()
                            if p.theyChokeUs { Image(systemName: "hand.raised.fill").help("Der Peer sperrt uns (Choke)") }
                            if p.weUnchoke { Image(systemName: "lock.open.fill").help("Wir geben diesem Peer Upload frei") }
                            if p.interested { Image(systemName: "heart.fill").help("Der Peer will Daten von uns") }
                            Text(Fmt.percent(p.progress)).monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: Tracker

    private var trackers: some View {
        Group {
            if engine.trackerList.isEmpty {
                ContentUnavailableView("Keine Tracker", systemImage: "antenna.radiowaves.left.and.right.slash")
            } else {
                List(engine.trackerList) { t in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: t.ok ? "checkmark.circle.fill" : (t.lastAnnounce == nil ? "circle.dotted" : "exclamationmark.triangle.fill"))
                                .foregroundStyle(t.ok ? .green : (t.lastAnnounce == nil ? Color.secondary : .orange))
                            Text(t.url).font(.callout).lineLimit(1).truncationMode(.middle)
                        }
                        HStack {
                            Text(t.status).lineLimit(2)
                            Spacer()
                            if t.ok { Text("\(t.peers) Peers") }
                            if let d = t.lastAnnounce { Text(d, style: .time) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: Log

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if engine.logs.isEmpty {
                        Text("Noch keine Meldungen").foregroundStyle(.tertiary)
                    } else {
                        Text(engine.logs.joined(separator: "\n")).textSelection(.enabled).detailWidth()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(10)
            }
            // scrollTo im selben Lauf wie das Layout lässt AppKit die Constraint-Pässe überziehen.
            .onChange(of: engine.logs.count) { _, _ in DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
}

private extension View {
    /// Markierbarer Text meldet sonst die volle Zeilenbreite; die Split-View legt die Constraint dann in jedem Pass neu an.
    func detailWidth() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

/// Piece-Karte: jedes Kästchen deckt einen Piece-Bereich ab, Deckkraft = Anteil geladen.
struct PieceMap: View {
    let engine: TorrentEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let bits = engine.pieceBitfield()
            let n = engine.torrent.numberOfPieces
            Canvas { ctx, size in
                guard n > 0 else { return }
                let cell: CGFloat = 7
                let cols = max(1, Int(size.width / cell))
                let cells = min(n, cols * 8)
                for c in 0..<cells {
                    let a = c * n / cells, b = max(a + 1, (c + 1) * n / cells)
                    var have = 0
                    for i in a..<b where bits[i / 8] & (1 << (7 - i % 8)) != 0 { have += 1 }
                    let f = Double(have) / Double(b - a)
                    let rect = CGRect(x: CGFloat(c % cols) * cell, y: CGFloat(c / cols) * cell, width: cell - 1, height: cell - 1)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(f > 0 ? Color.accentColor.opacity(0.25 + 0.75 * f) : Color.secondary.opacity(0.15)))
                }
            }
            .frame(height: 56)
        }
    }
}
