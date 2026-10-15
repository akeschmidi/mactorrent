import Foundation
import Network

/// Minimaler HTTP(S)-GET über Network.framework. Grund: URLSession sendet einen User-Agent mit App-Name
/// und macOS-Version und lässt sich nicht an eine Schnittstelle binden. Hier gibt es keine Zusatz-Header,
/// und `NetworkPolicy` (VPN-Schutz) gilt auch für Tracker und .torrent-Downloads.
public enum HTTPClient {
    public struct HTTPError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private static let maxBytes = 16 * 1024 * 1024

    public static func get(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var current = url
        for _ in 0..<5 {
            let (status, headers, body) = try await fetch(current, timeout: timeout)
            if [301, 302, 303, 307, 308].contains(status), let loc = headers["location"],
               let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                // Weder von https auf http zurückfallen (Inhalt austauschbar) noch ins lokale Netz umleiten lassen.
                if current.scheme?.lowercased() == "https", next.scheme?.lowercased() != "https" {
                    throw HTTPError(message: String(localized: "Weiterleitung von https auf http abgelehnt", bundle: .main))
                }
                if !NetworkPolicy.shared.allowLocalTrackers, NetworkPolicy.isLocalHost(next.host), !NetworkPolicy.isLocalHost(current.host) {
                    throw HTTPError(message: String(localized: "Weiterleitung ins lokale Netz abgelehnt", bundle: .main))
                }
                current = next
                continue
            }
            guard status == 200 else { throw HTTPError(message: "HTTP \(status)") }
            return body
        }
        throw HTTPError(message: String(localized: "Zu viele Weiterleitungen", bundle: .main))
    }

    /// Einmalige Anfrage ohne Weiterleitungen, auch mit Fehlerstatus und Antworttext (für UPnP/SOAP).
    public static func request(_ url: URL, method: String, headers: [String: String] = [:], body: Data? = nil,
                               timeout: TimeInterval = 10) async throws -> (status: Int, body: Data) {
        let r = try await fetch(url, timeout: timeout, method: method, headers: headers, body: body)
        return (r.0, r.2)
    }

    private static func fetch(_ url: URL, timeout: TimeInterval, method: String = "GET",
                              headers: [String: String] = [:], body: Data? = nil) async throws -> (Int, [String: String], Data) {
        guard let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.badURL)
        }
        let policy = NetworkPolicy.shared
        guard !policy.isBlocked else { throw HTTPError(message: String(localized: "VPN-Schutz: Schnittstelle nicht verbunden", bundle: .main)) }
        let tls = scheme == "https"
        let portNum = UInt16(url.port ?? (tls ? 443 : 80))
        let conn = NWConnection(host: .init(host), port: NWEndpoint.Port(rawValue: portNum)!,
                                using: policy.parameters(tls ? NWParameters(tls: .init()) : .tcp))
        defer { conn.cancel() }

        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        var target = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let q = comps.percentEncodedQuery { target += "?" + q }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        // GET über HTTP/1.0: keine Chunked-Antwort, Server schließt am Ende. Kein User-Agent.
        var head = "\(method) \(target) HTTP/\(body == nil ? "1.0" : "1.1")\r\nHost: \(hostHeader)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        var request = Data((head + "\r\n").utf8)
        if let body { request.append(body) }

        let payload = request
        let raw: Data = try await withCheckedThrowingContinuation { cont in
            let box = Box(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { err in if let err { box.fail(err) } })
                    receive(conn, box)
                case .failed(let e): box.fail(e)
                case .waiting(let e): box.fail(e) // z. B. Schnittstelle weg: nicht ewig warten
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.fail(URLError(.timedOut)) }
        }
        return try parse(raw)
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var cont: CheckedContinuation<Data, Error>?
        var data = Data()
        init(_ c: CheckedContinuation<Data, Error>) { cont = c }
        func fail(_ e: Error) { finish { $0.resume(throwing: e) } }
        func done() { let d = data; finish { $0.resume(returning: d) } }
        private func finish(_ f: (CheckedContinuation<Data, Error>) -> Void) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            if let c { f(c) }
        }
    }

    private static func receive(_ conn: NWConnection, _ box: Box) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data { box.data.append(data) }
            if box.data.count > maxBytes { box.fail(HTTPError(message: String(localized: "Antwort zu groß", bundle: .main))); return }
            if isComplete || error != nil { box.done(); return }
            receive(conn, box)
        }
    }

    private static func parse(_ raw: Data) throws -> (Int, [String: String], Data) {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { throw HTTPError(message: String(localized: "Ungültige Antwort", bundle: .main)) }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head[0].split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw HTTPError(message: String(localized: "Ungültige Antwort", bundle: .main)) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data(raw[split.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { body = dechunk(body) }
        return (status, headers, body)
    }

    private static func dechunk(_ d: Data) -> Data {
        var out = Data(), rest = d
        while let crlf = rest.range(of: Data("\r\n".utf8)),
              let size = Int(String(decoding: rest[..<crlf.lowerBound], as: UTF8.self).split(separator: ";")[0], radix: 16),
              size > 0, rest.count >= crlf.upperBound + size {
            out.append(rest[crlf.upperBound ..< crlf.upperBound + size])
            rest = Data(rest[(crlf.upperBound + size)...].dropFirst(2))
        }
        return out
    }
}
