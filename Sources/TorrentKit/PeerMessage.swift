import Foundation

/// BitTorrent Peer-Messages (Payload eines Frames, inkl. 1 Byte Type).
public enum PeerMessage {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(piece: Int)
    case bitfield(Data)
    case piece(piece: Int, offset: Int, data: Data)
    case request(piece: Int, offset: Int, length: Int)
    case cancel
    case ping
    case pong
    case extensionMessage(Int)
    case unknown
}

extension PeerMessage {
    /// Dekodiert ein Frame-Payload ([1 Byte Type][…]).
    static func parse(_ payload: Data) -> PeerMessage {
        guard let type = payload.first else { return .unknown }
        let body = payload.dropFirst()
        switch type {
        case 0: return .keepAlive
        case 1: return .choke
        case 2: return .unchoke
        case 3: return .interested
        case 4: return body.count >= 4 ? .have(piece: be32(body.prefix(4))) : .unknown
        case 5: return .bitfield(Data(body))
        case 7:
            guard body.count >= 8 else { return .unknown }
            let piece = be32(body.prefix(4))
            let offset = be32(body.dropFirst(4).prefix(4))
            let data = Data(body.dropFirst(8))
            return .piece(piece: piece, offset: offset, data: data)
        case 6:
            guard body.count >= 12 else { return .unknown }
            return .request(piece: be32(body.prefix(4)),
                            offset: be32(body.dropFirst(4).prefix(4)),
                            length: be32(body.dropFirst(8).prefix(4)))
        case 8: return .cancel
        case 0x10: return .ping
        case 0x11: return .pong
        default: return .extensionMessage(Int(type))
        }
    }

    private static func be32(_ bytes: some Sequence<UInt8>) -> Int {
        let a = Array(bytes)
        guard a.count == 4 else { return 0 }
        return Int(a[0]) << 24 | Int(a[1]) << 16 | Int(a[2]) << 8 | Int(a[3])
    }
}
