import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TorrentKit

/// Ein Dialog für alles: Links einfügen (je Zeile), Dateien wählen oder hineinziehen, Zielordner wählen.
struct AddTorrentsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var files: [URL] = []
    @State private var destination: URL?

    private var linkCount: Int {
        text.split(whereSeparator: \.isNewline).flatMap { $0.split(separator: " ") }
            .filter { $0.hasPrefix("magnet:") || $0.hasPrefix("http") || $0.hasPrefix("/") || $0.hasPrefix("file://") }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Torrents hinzufügen").font(.title3.bold())

            Text("Magnet-Links oder .torrent-Adressen – ein Eintrag pro Zeile").font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("magnet:?xt=urn:btih:…\nhttps://…/datei.torrent").foregroundStyle(.tertiary)
                            .font(.system(.body, design: .monospaced)).padding(8).allowsHitTesting(false)
                    }
                }

            HStack {
                Text("Dateien").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Dateien wählen…", action: pickFiles)
            }
            if files.isEmpty {
                Text("Oder .torrent-Dateien hierher ziehen").font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, style: StrokeStyle(dash: [5])))
            } else {
                List {
                    ForEach(files, id: \.self) { f in
                        HStack {
                            Image(systemName: "doc")
                            Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { files.removeAll { $0 == f } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: min(130, CGFloat(files.count) * 28 + 8))
            }

            LabeledContent("Speichern in") {
                HStack {
                    Text((destination ?? model.defaultDestination).map { FolderAccess.tilde($0.path) } ?? String(localized: "Noch nicht gewählt"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Ändern…", action: pickDestination)
                    if destination != nil { Button("Standard") { destination = nil } }
                }
            }

            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hinzufügen") {
                    model.addInput(text: text, files: files, destination: destination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkCount == 0 && files.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .dropDestination(for: URL.self) { urls, _ in
            files.append(contentsOf: urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "torrent" && !files.contains($0) })
            return true
        }
        .onAppear(perform: prefillFromClipboard)
    }

    private var summary: String {
        let n = linkCount + files.count
        return n == 0 ? "" : "\(n) Torrent\(n == 1 ? "" : "s") bereit"
    }

    /// Liegt ein Magnet-Link in der Zwischenablage, steht er schon da.
    private func prefillFromClipboard() {
        guard text.isEmpty, let s = NSPasteboard.general.string(forType: .string) else { return }
        let lines = s.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasPrefix("magnet:") || ($0.hasPrefix("http") && $0.contains(".torrent")) }
        text = lines.joined(separator: "\n")
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        if panel.runModal() == .OK { files.append(contentsOf: panel.urls.filter { !files.contains($0) }) }
    }

    private func pickDestination() {
        if let url = FolderAccess.choose(message: String(localized: "Ordner für diese Downloads freigeben")) { destination = url }
    }
}
