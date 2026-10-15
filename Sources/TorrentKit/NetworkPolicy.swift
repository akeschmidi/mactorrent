import Foundation
import Network

/// Datenschutz-Regeln für alle Verbindungen der Engine.
/// - `interfaceName`: erzwingt eine Schnittstelle (z. B. ein VPN `utun4`). Fehlt sie, wird nichts gesendet (Kill-Switch).
/// - `anonymous`: sendet keine Client-Kennung, hört nicht auf eingehende Verbindungen und
///   meldet sich nirgends als Peer an (kein DHT-Announce, keine Transfer-Zahlen an Tracker).
/// BitTorrent zeigt Peers immer die IP – echte Anonymität liefert nur ein VPN, das dieser Schalter erzwingt.
public final class NetworkPolicy: @unchecked Sendable {
    public static let shared = NetworkPolicy()

    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var name: String?
    private var anon = false
    private var localOK = false
    /// Wird bei jeder Änderung der verfügbaren Schnittstellen aufgerufen (Hintergrund-Thread).
    public var onChange: (@Sendable () -> Void)?

    private init() {
        let first = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.path = p; self.lock.unlock()
            first.signal()
            self.onChange?()
        }
        monitor.start(queue: DispatchQueue(label: "ch.stefan.mactorrent.netpolicy"))
        // Erst die erste Pfadmeldung abwarten: sonst wirkt eine erzwungene Schnittstelle beim Start fälschlich „nicht verbunden“.
        _ = first.wait(timeout: .now() + 1)
    }

    public var interfaceName: String? {
        get { lock.lock(); defer { lock.unlock() }; return name }
        set { lock.lock(); name = (newValue?.isEmpty ?? true) ? nil : newValue; lock.unlock() }
    }

    public var anonymous: Bool {
        get { lock.lock(); defer { lock.unlock() }; return anon }
        set { lock.lock(); anon = newValue; lock.unlock() }
    }

    /// Tracker/Weiterleitungen im lokalen Netz zulassen (Standard: nein, sonst könnte ein fremder Torrent
    /// per Tracker-URL GET-Anfragen an Router oder Geräte im LAN schicken).
    public var allowLocalTrackers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return localOK }
        set { lock.lock(); localOK = newValue; lock.unlock() }
    }

    /// Loopback, private, Link-Local-Adressen und `.local`-Namen (nur Literale/Namen, kein DNS-Lookup).
    public static func isLocalHost(_ host: String?) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("[") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") { return true }
        if h == "::1" || h == "::" || h.hasPrefix("fe80:") || h.hasPrefix("fc") && h.contains(":") || h.hasPrefix("fd") && h.contains(":") { return true }
        let o = h.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4, o.allSatisfy({ (0...255).contains($0) }) else { return false }
        return o[0] == 127 || o[0] == 10 || o[0] == 0 || (o[0] == 192 && o[1] == 168)
            || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 169 && o[1] == 254)
    }

    /// IPv4-Adresse des Standard-Gateways (für NAT-PMP/UPnP), falls bekannt.
    public var gatewayIPv4: String? {
        lock.lock(); defer { lock.unlock() }
        for g in path?.gateways ?? [] {
            if case let .hostPort(h, _) = g, case .ipv4 = h { return "\(h)".split(separator: "%").first.map(String.init) }
        }
        return nil
    }

    public var availableInterfaces: [NWInterface] {
        lock.lock(); defer { lock.unlock() }
        return path?.availableInterfaces ?? []
    }

    /// Die erzwungene Schnittstelle, solange sie verfügbar ist.
    public var interface: NWInterface? {
        guard let n = interfaceName else { return nil }
        return availableInterfaces.first { $0.name == n }
    }

    /// Schnittstelle erzwungen, aber nicht verbunden → keine Verbindung erlaubt.
    public var isBlocked: Bool { interfaceName != nil && interface == nil }

    /// Fügt die erzwungene Schnittstelle zu den Parametern hinzu.
    public func parameters(_ base: NWParameters) -> NWParameters {
        if let i = interface { base.requiredInterface = i }
        return base
    }
}
