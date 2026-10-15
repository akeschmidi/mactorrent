import SwiftUI
import AppKit
import Network
import TorrentKit

/// UserDefaults-Schlüssel. AppModel liest sie, SettingsView schreibt sie per @AppStorage.
enum Pref {
    static let downloadPath = "downloadPath"
    static let incompletePath = "incompletePath"
    static let downLimitKB = "downLimitKB"
    static let upLimitKB = "upLimitKB"
    static let maxPeers = "maxPeers"
    static let listenPort = "listenPort"
    static let portMapping = "portMapping"
    static func randomPort() -> Int { Int.random(in: 20_000...60_000) }
    static let publicTrackers = "publicTrackers"
    static let dhtEnabled = "dhtEnabled"
    static let boundInterface = "boundInterface"
    static let anonymousMode = "anonymousMode"
    static let allowLocalTrackers = "allowLocalTrackers"
    static let autoResume = "autoResume"
    static let notify = "notify"
    static let dockBadge = "dockBadge"
    static let menuBar = "menuBar"

    static func registerDefaults() {
        // Einmal würfeln und merken: ein Port, der bei jedem Start wechselt, lässt sich nicht im Router weiterleiten.
        if UserDefaults.standard.object(forKey: listenPort) == nil {
            UserDefaults.standard.set(randomPort(), forKey: listenPort)
        }
        UserDefaults.standard.register(defaults: [
            downloadPath: "", incompletePath: "", downLimitKB: 0, upLimitKB: 0, maxPeers: 50,
            publicTrackers: true, dhtEnabled: true, portMapping: true, boundInterface: "", anonymousMode: true, allowLocalTrackers: false, autoResume: true, notify: true, dockBadge: true, menuBar: true,
        ])
    }
}

struct SettingsView: View {
    @AppStorage(Pref.downloadPath) private var downloadPath = ""
    @AppStorage(Pref.incompletePath) private var incompletePath = ""
    @AppStorage(Pref.downLimitKB) private var downLimitKB = 0
    @AppStorage(Pref.upLimitKB) private var upLimitKB = 0
    @AppStorage(Pref.maxPeers) private var maxPeers = 50
    @AppStorage(Pref.listenPort) private var listenPort = 6881
    @AppStorage(Pref.portMapping) private var portMapping = true
    @ObservedObject var model: AppModel
    @AppStorage(Pref.publicTrackers) private var publicTrackers = true
    @AppStorage(Pref.dhtEnabled) private var dhtEnabled = true
    @AppStorage(Pref.boundInterface) private var boundInterface = ""
    @AppStorage(Pref.anonymousMode) private var anonymousMode = true
    @AppStorage(Pref.allowLocalTrackers) private var allowLocalTrackers = false
    @State private var interfaces: [NWInterface] = []
    @AppStorage(Pref.autoResume) private var autoResume = true
    @AppStorage(Pref.notify) private var notify = true
    @AppStorage(Pref.dockBadge) private var dockBadge = true
    @AppStorage(Pref.menuBar) private var menuBar = true

    var body: some View {
        TabView {
            general.tabItem { Label("Allgemein", systemImage: "gearshape") }
            network.tabItem { Label("Netzwerk", systemImage: "network") }
            privacy.tabItem { Label("Privatsphäre", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 500)
    }

    private var general: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Speicherort") {
                    HStack {
                        Text(downloadPath.isEmpty ? String(localized: "Noch nicht gewählt") : shown(downloadPath))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Wählen…") { if let p = chooseFolder(String(localized: "Ordner für Downloads freigeben")) { downloadPath = p } }
                    }
                }
                LabeledContent("Unfertige Downloads") {
                    HStack {
                        Text(incompletePath.isEmpty ? String(localized: "wie Speicherort") : shown(incompletePath))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Wählen…") { if let p = chooseFolder(String(localized: "Ordner für unfertige Downloads freigeben")) { incompletePath = p } }
                        if !incompletePath.isEmpty { Button("Aus") { incompletePath = "" } }
                    }
                }
                Text("Mit Unfertig-Ordner lädt ein Torrent dort und wird nach dem Download in den Speicherort verschoben. Gilt für neu hinzugefügte Torrents.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Aktive Downloads beim Start fortsetzen", isOn: $autoResume)
            }
            Section("Mitteilungen") {
                Toggle("Benachrichtigung, wenn ein Download fertig ist", isOn: $notify)
                Toggle("Anzahl aktiver Downloads am Dock-Symbol", isOn: $dockBadge)
                Toggle("Symbol mit Geschwindigkeit in der Menüleiste", isOn: $menuBar)
            }
        }
        .formStyle(.grouped)
    }

    private var network: some View {
        Form {
            Section("Geschwindigkeit") {
                LabeledContent("Download-Limit") { limitField($downLimitKB) }
                LabeledContent("Upload-Limit") { limitField($upLimitKB) }
            }
            Section("Verbindungen") {
                LabeledContent("Max. Peers pro Torrent") {
                    Stepper(value: $maxPeers, in: 5...200, step: 5) {
                        Text("\(maxPeers)").monospacedDigit()
                    }
                }
                LabeledContent("Port für eingehende Verbindungen") {
                    HStack {
                        TextField("", value: $listenPort, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .onChange(of: listenPort) { _, v in
                                if v < 1024 || v > 65535 { listenPort = min(65535, max(1024, v)) }
                            }
                        Button("Zufällig") { listenPort = Pref.randomPort() }
                    }
                }
                Toggle("Port automatisch am Router freigeben (UPnP/NAT-PMP)", isOn: $portMapping)
                Text(model.portStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Text("TCP, gilt für alle Torrents. Klappt die automatische Freigabe nicht, leite den Port im Router selbst an diesen Mac weiter. Im anonymen Modus und bei erzwungener VPN-Schnittstelle bleibt der Port geschlossen.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("DHT nutzen (Peers ohne Tracker finden)", isOn: $dhtEnabled)
                Toggle("Zusätzliche öffentliche Tracker nutzen", isOn: $publicTrackers)
                Text("Private Torrents verwenden nie DHT oder fremde Tracker. DHT-Änderungen gelten für neu gestartete Torrents.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("VPN-Schutz (Kill-Switch)") {
                Picker("Nur über Schnittstelle", selection: $boundInterface) {
                    Text("Alle Verbindungen (kein Schutz)").tag("")
                    ForEach(interfaces, id: \.name) { Text(label($0)).tag($0.name) }
                    if !boundInterface.isEmpty && !interfaces.contains(where: { $0.name == boundInterface }) {
                        Text("\(boundInterface) (nicht verbunden)").tag(boundInterface)
                    }
                }
                Text("Peers, Tracker und DHT laufen dann ausschließlich über diese Schnittstelle, zum Beispiel dein VPN (utun…). Ist sie nicht verbunden, sendet die App nichts und pausiert alle Torrents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anonymer Modus") {
                Toggle("Möglichst wenig über mich preisgeben", isOn: $anonymousMode)
                Text("Zufällige Peer-ID ohne Client-Kürzel · keine eingehenden Verbindungen (kein offener Port) · kein Eintrag im DHT · keine öffentlichen Zusatz-Tracker · Tracker erfahren keine Transfer-Zahlen · kein User-Agent. Gilt für neu gestartete Torrents. Seeding ist so nur eingeschränkt möglich.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sicherheit") {
                Toggle("Tracker im lokalen Netz erlauben", isOn: $allowLocalTrackers)
                Text("Standardmäßig blockiert: Ein fremder Torrent könnte sonst über seine Tracker-Adresse Anfragen an deinen Router oder andere Geräte im Heimnetz schicken.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Wichtig: BitTorrent zeigt jedem Peer im Schwarm deine IP-Adresse. Das kann keine App ändern. Echten Schutz bietet nur ein VPN – der Kill-Switch oben stellt sicher, dass die App ohne VPN gar nicht sendet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { interfaces = NetworkPolicy.shared.availableInterfaces.filter { $0.type != .loopback } }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            interfaces = NetworkPolicy.shared.availableInterfaces.filter { $0.type != .loopback }
        }
    }

    private func label(_ i: NWInterface) -> String {
        let kind: String
        switch i.type {
        case .wifi: kind = "WLAN"
        case .wiredEthernet: kind = "Ethernet"
        case .cellular: kind = "Mobilfunk"
        default: kind = i.name.hasPrefix("utun") || i.name.hasPrefix("ppp") || i.name.hasPrefix("ipsec") ? "VPN/Tunnel" : "Sonstige"
        }
        return "\(i.name) – \(kind)"
    }

    private func limitField(_ value: Binding<Int>) -> some View {
        HStack {
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text("KB/s  (0 = unbegrenzt)").foregroundStyle(.secondary)
        }
    }

    private func shown(_ path: String) -> String { FolderAccess.tilde(path) }

    private func chooseFolder(_ message: String) -> String? {
        FolderAccess.choose(message: message, prompt: String(localized: "Zugriff erlauben"))?.path
    }
}
