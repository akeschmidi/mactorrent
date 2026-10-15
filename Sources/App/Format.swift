import Foundation

/// Einheitliche Anzeige-Formate (lokalisiert über Foundation).
enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func rate(_ b: Int64) -> String {
        b > 0 ? bytes(b) + "/s" : "–"
    }

    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f
    }()

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds < 60 * 60 * 24 * 365 else { return "–" }
        return etaFormatter.string(from: max(1, seconds)) ?? "–"
    }

    /// Kurz für die Menüleiste: „1,2 MB“ statt „1,2 MB/s“, „–“ bei 0.
    static func compactRate(_ b: Int64) -> String {
        b > 0 ? ByteCountFormatter.string(fromByteCount: b, countStyle: .file) : "0"
    }

    static func percent(_ f: Double) -> String {
        f.formatted(.percent.precision(.fractionLength(f >= 1 || f == 0 ? 0 : 1)))
    }
}
