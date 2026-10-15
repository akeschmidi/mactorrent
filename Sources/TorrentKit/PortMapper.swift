import Foundation
import Network

/// Öffnet den Listen-Port am Router, damit andere Peers uns erreichen: erst NAT-PMP (einfach, schnell), dann UPnP (IGD).
/// Nur im LAN sinnvoll – bei erzwungener VPN-Schnittstelle oder anonymem Modus wird nichts freigegeben.
public actor PortMapper {
    public struct Mapping: Sendable, Equatable {
        public let method: String        // "NAT-PMP" oder "UPnP"
        public let port: Int
        public let externalIP: String?
    }

    struct Config: Sendable {
        var gateway: String?             // nil = Standard-Gateway aus NetworkPolicy
        var natPMPPort: UInt16 = 5351
        var ssdpPort: UInt16 = 1900
        var timeout: TimeInterval = 1.5
    }

    public static let shared = PortMapper()
    private let config: Config
    private var current: Mapping?
    private var upnp: (control: URL, service: String)?
    private var renewal: Task<Void, Never>?
    private static let lease = 3600

    public init() { config = Config() }
    init(config: Config) { self.config = config }

    public var mapping: Mapping? { current }

    /// Versucht NAT-PMP, dann UPnP. Erneuert die Freigabe regelmäßig, bis `unmap()` aufgerufen wird.
    @discardableResult
    public func map(port: Int) async -> Mapping? {
        renewal?.cancel()
        guard let gw = config.gateway ?? NetworkPolicy.shared.gatewayIPv4 else { current = nil; return nil }
        var found = await natPMP(gateway: gw, port: port)
        if found == nil { found = await upnpMap(gateway: gw, port: port) }
        if let m = found {
            current = m
            renewal = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double(Self.lease) / 2))
                    guard !Task.isCancelled else { return }
                    _ = await self?.map(port: port)
                }
            }
            return m
        }
        current = nil
        return nil
    }

    public func unmap() async {
        renewal?.cancel()
        guard let m = current else { return }
        current = nil
        guard let gw = config.gateway ?? NetworkPolicy.shared.gatewayIPv4 else { return }
        if m.method == "NAT-PMP" { _ = await natPMPRequest(gateway: gw, port: m.port, lifetime: 0) }
        else if let u = upnp { _ = await soap(u.control, u.service, "DeletePortMapping",
            "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(m.port)</NewExternalPort><NewProtocol>TCP</NewProtocol>") }
    }

    // MARK: NAT-PMP (RFC 6886)

    private func natPMPRequest(gateway: String, port: Int, lifetime: Int) async -> Int? {
        guard let p = NWEndpoint.Port(rawValue: config.natPMPPort) else { return nil }
        let conn = NWConnection(host: .init(gateway), port: p, using: .udp)
        defer { conn.cancel() }
        var req = Data([0, 2, 0, 0])   // Version 0, Op 2 = TCP, reserviert
        for v in [port, port] { req.append(UInt8((v >> 8) & 0xFF)); req.append(UInt8(v & 0xFF)) }
        for s in [24, 16, 8, 0] { req.append(UInt8((lifetime >> s) & 0xFF)) }
        guard let r = try? await UDPIO(conn).exchange(req, timeout: config.timeout, tries: 2),
              r.count >= 16, r[r.startIndex + 1] == 130, r[r.startIndex + 2] == 0, r[r.startIndex + 3] == 0 else { return nil }
        let b = Array(r)
        return Int(b[10]) << 8 | Int(b[11]) // zugewiesener externer Port
    }

    private func natPMPExternalIP(gateway: String) async -> String? {
        guard let p = NWEndpoint.Port(rawValue: config.natPMPPort) else { return nil }
        let conn = NWConnection(host: .init(gateway), port: p, using: .udp)
        defer { conn.cancel() }
        guard let r = try? await UDPIO(conn).exchange(Data([0, 0]), timeout: config.timeout, tries: 2), r.count >= 12 else { return nil }
        let b = Array(r)
        guard b[1] == 128, b[2] == 0, b[3] == 0 else { return nil }
        return "\(b[8]).\(b[9]).\(b[10]).\(b[11])"
    }

    private func natPMP(gateway: String, port: Int) async -> Mapping? {
        guard let ext = await natPMPRequest(gateway: gateway, port: port, lifetime: Self.lease) else { return nil }
        return Mapping(method: "NAT-PMP", port: ext, externalIP: await natPMPExternalIP(gateway: gateway))
    }

    // MARK: UPnP IGD

    private func upnpMap(gateway: String, port: Int) async -> Mapping? {
        guard let (control, service, local) = await discoverIGD(gateway: gateway) else { return nil }
        upnp = (control, service)
        func add(_ lease: Int) async -> (Int, String) {
            await soap(control, service, "AddPortMapping", """
                <NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>TCP</NewProtocol>\
                <NewInternalPort>\(port)</NewInternalPort><NewInternalClient>\(local)</NewInternalClient><NewEnabled>1</NewEnabled>\
                <NewPortMappingDescription>MacTorrent</NewPortMappingDescription><NewLeaseDuration>\(lease)</NewLeaseDuration>
                """)
        }
        var res = await add(Self.lease)
        if res.0 != 200, res.1.contains("725") { res = await add(0) } // Router erlaubt nur dauerhafte Einträge
        guard res.0 == 200 else { return nil }
        let ip = await soap(control, service, "GetExternalIPAddress", "").1
        return Mapping(method: "UPnP", port: port, externalIP: Self.tag("NewExternalIPAddress", in: ip))
    }

    /// SSDP-Suche (direkt beim Gateway, ohne Multicast), danach Gerätebeschreibung laden und den WAN-Dienst suchen.
    private func discoverIGD(gateway: String) async -> (URL, String, String)? {
        guard let p = NWEndpoint.Port(rawValue: config.ssdpPort) else { return nil }
        let conn = NWConnection(host: .init(gateway), port: p, using: .udp)
        defer { conn.cancel() }
        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        guard let r = try? await UDPIO(conn).exchange(Data(search.utf8), timeout: config.timeout, tries: 2) else { return nil }
        let text = String(decoding: r, as: UTF8.self)
        guard let loc = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") })?
                .dropFirst(9).trimmingCharacters(in: .whitespaces),
              let descURL = URL(string: loc), let host = descURL.host,
              host == gateway || NetworkPolicy.isLocalHost(host) else { return nil } // nur Geräte im LAN
        guard let (status, body) = try? await HTTPClient.request(descURL, method: "GET"), status == 200,
              let (servicePath, type) = Self.parseService(body),
              let control = URL(string: servicePath, relativeTo: descURL)?.absoluteURL else { return nil }
        return (control, type, await localAddress(toward: gateway) ?? "")
    }

    private func localAddress(toward gateway: String) async -> String? {
        let conn = NWConnection(host: .init(gateway), port: 9, using: .udp)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            conn.stateUpdateHandler = { st in
                if case .ready = st {
                    if case let .hostPort(h, _)? = conn.currentPath?.localEndpoint, once.fire() {
                        cont.resume(returning: "\(h)".split(separator: "%").first.map(String.init))
                    }
                    conn.cancel()
                } else if case .failed = st, once.fire() { cont.resume(returning: nil) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if once.fire() { cont.resume(returning: nil); conn.cancel() } }
        }
    }

    private func soap(_ control: URL, _ service: String, _ action: String, _ args: String) async -> (Int, String) {
        let body = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
            """
        let headers = ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(service)#\(action)\""]
        guard let r = try? await HTTPClient.request(control, method: "POST", headers: headers, body: Data(body.utf8)) else { return (0, "") }
        return (r.status, String(decoding: r.body, as: UTF8.self))
    }

    // MARK: XML

    static func tag(_ name: String, in xml: String) -> String? {
        guard let a = xml.range(of: "<\(name)>"), let b = xml.range(of: "</\(name)>", range: a.upperBound..<xml.endIndex) else { return nil }
        return String(xml[a.upperBound..<b.lowerBound])
    }

    /// Findet den WANIPConnection-/WANPPPConnection-Dienst in der Gerätebeschreibung: (controlURL, serviceType).
    static func parseService(_ xml: Data) -> (String, String)? {
        final class P: NSObject, XMLParserDelegate {
            var text = "", type = "", control = ""
            var found: (String, String)?
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
            func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if e == "serviceType" { type = t }
                if e == "controlURL" { control = t }
                if e == "service", found == nil, type.contains("WANIPConnection") || type.contains("WANPPPConnection"), !control.isEmpty {
                    found = (control, type)
                }
                if e == "service" { type = ""; control = "" }
            }
        }
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        let p = P()
        parser.delegate = p
        parser.parse()
        return p.found
    }
}
