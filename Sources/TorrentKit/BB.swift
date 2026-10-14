import Foundation
import CryptoKit

/// Minimaler bencode-Codec (BT-Metafiles + Peer-Meldungen).
/// Decode: Strings werden als `Data` zurückgegeben (Data ≠ String in Swift).
public enum BB {
    // MARK: - Encode

    public static func encode(_ value: Any) throws -> Data {
        var out = Data()
        try append(value, into: &out)
        return out
    }

    private static func append(_ value: Any, into data: inout Data) throws {
        switch value {
        case let i as Int:
            data.append("i\(i)e".data(using: .ascii)!)
        case let d as Data:
            data.append("\(d.count):".data(using: .ascii)!)
            data.append(d)
        case let s as String:
            let b = s.data(using: .utf8)!
            data.append("\(b.count):".data(using: .ascii)!)
            data.append(b)
        case let a as [Any]:
            data.append("l".data(using: .ascii)!)
            for v in a { try append(v, into: &data) }
            data.append("e".data(using: .ascii)!)
        case let d as [String: Any]:
            data.append("d".data(using: .ascii)!)
            for key in d.keys.sorted(by: <) {
                let kb = key.data(using: .utf8)!
                data.append("\(kb.count):".data(using: .ascii)!)
                data.append(kb)
                try append(d[key]!, into: &data)
            }
            data.append("e".data(using: .ascii)!)
        default:
            throw BBError.unsupportedType(String(describing: type(of: value)))
        }
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> Any {
        let bytes = [UInt8](data)
        var cursor = 0
        let value = try parseValue(bytes, &cursor)
        guard cursor == bytes.count else { throw BBError.trailingBytes }
        return value
    }

    /// Dekodiert, ignoriert ggf. Bytes am Ende (robust gegenüber Tracker-Antworten mit Makulatur).
    public static func decodeTolerant(_ data: Data) throws -> Any {
        let bytes = [UInt8](data)
        var cursor = 0
        return try parseValue(bytes, &cursor)
    }

    private static func parseValue(_ bytes: [UInt8], _ c: inout Int) throws -> Any {
        guard c < bytes.count else { throw BBError.unexpectedEnd }
        switch bytes[c] {
        case UInt8(ascii: "i"):
            return try parseInt(bytes, &c)
        case UInt8(ascii: "l"):
            return try parseList(bytes, &c)
        case UInt8(ascii: "d"):
            return try parseDict(bytes, &c)
        default:
            if Character(UnicodeScalar(bytes[c])).isNumber {
                return try parseString(bytes, &c)
            }
            throw BBError.invalidTypeIndicator(bytes[c])
        }
    }

    private static func parseInt(_ bytes: [UInt8], _ c: inout Int) throws -> Int {
        c += 1
        guard let end = indexOf(bytes, UInt8(ascii: "e"), from: c), end > c else { throw BBError.invalidInteger }
        let s = String(bytes: bytes[c..<end], encoding: .ascii)!
        guard let v = Int(s) else { throw BBError.invalidInteger }
        c = end + 1
        return v
    }

    private static func parseString(_ bytes: [UInt8], _ c: inout Int) throws -> Data {
        guard let colon = indexOf(bytes, UInt8(ascii: ":"), from: c) else { throw BBError.invalidLength }
        let len = Int(String(bytes: bytes[c..<colon], encoding: .ascii)!)
            ?? 0
        let start = colon + 1
        guard start + len <= bytes.count else { throw BBError.stringOverflow }
        let value = Data(bytes[start..<(start + len)])
        c = start + len
        return value
    }

    private static func parseList(_ bytes: [UInt8], _ c: inout Int) throws -> [Any] {
        c += 1 // 'l'
        var items: [Any] = []
        while c < bytes.count && bytes[c] != UInt8(ascii: "e") {
            items.append(try parseValue(bytes, &c))
        }
        guard c < bytes.count else { throw BBError.unexpectedEnd }
        c += 1 // 'e'
        return items
    }

    private static func parseDict(_ bytes: [UInt8], _ c: inout Int) throws -> [String: Any] {
        c += 1 // 'd'
        var dict: [String: Any] = [:]
        while c < bytes.count && bytes[c] != UInt8(ascii: "e") {
            let key = try parseString(bytes, &c)
            guard let keyStr = String(data: key, encoding: .utf8) else { throw BBError.invalidKey }
            dict[keyStr] = try parseValue(bytes, &c)
        }
        guard c < bytes.count else { throw BBError.unexpectedEnd }
        c += 1 // 'e'
        return dict
    }

    private static func indexOf(_ bytes: [UInt8], _ target: UInt8, from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == target { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Typ-Helfer

    public static func dict(_ value: Any) throws -> [String: Any] {
        guard let d = value as? [String: Any] else { throw BBError.notADict }
        return d
    }

    public static func int(_ value: Any?) -> Int? { value as? Int }
    public static func string(_ value: Any?) -> String? {
        guard let d = value as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public static func list(_ value: Any?) -> [Any]? { value as? [Any] }
    public static func data(_ value: Any?) -> Data? { value as? Data }
}

public enum BBError: Error, CustomStringConvertible {
    case unsupportedType(String)
    case trailingBytes
    case unexpectedEnd
    case invalidTypeIndicator(UInt8)
    case invalidInteger
    case invalidLength
    case stringOverflow
    case invalidKey
    case notADict

    public var description: String {
        switch self {
        case .unsupportedType(let t): return "Unsupported bencode type: \(t)"
        case .trailingBytes: return "Trailing bytes after value"
        case .unexpectedEnd: return "Unexpected end of input"
        case .invalidTypeIndicator(let b): return "Invalid bencode type indicator: \(b)"
        case .invalidInteger: return "Invalid bencode integer"
        case .invalidLength: return "Invalid bencode string length"
        case .stringOverflow: return "String length exceeds available bytes"
        case .invalidKey: return "Invalid dictionary key"
        case .notADict: return "Expected bencode dict"
        }
    }
}
