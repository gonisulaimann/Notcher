import Foundation

/// Notcher Link — local-only sync protocol between the Mac island and the
/// iPhone companion. No cloud, no accounts. Transport is plain TCP over the
/// local network (Bonjour `_notcherlink._tcp`); every frame after the salt
/// handshake is sealed with AES-GCM using a key derived from a 6-digit
/// pairing code the user types on both devices.
///
/// Wire format (TCP stream):
///   [4-byte big-endian length N][N bytes payload]
/// Payload is either a plaintext handshake frame (`{ "v":..., "salt":... }`
/// with kind == "salt") or an AES-GCM combined sealed box
/// (nonce 12B || ciphertext || tag 16B) whose plaintext is a JSON Message.
public enum LinkProtocol {
    public static let serviceType = "_notcherlink._tcp"
    public static let serviceDomain: String? = nil
    public static let protocolVersion = 1
    public static let heartbeatInterval: TimeInterval = 5
    public static let peerTimeoutInterval: TimeInterval = 15
    public static let maxFileBytes = 25 * 1024 * 1024
    public static let fileChunkBytes = 32 * 1024
    public static let authMagic = "notcher-link-auth-v1"
}

/// A single protocol message. Flat struct (instead of an enum with
/// associated values) so it stays Codable without custom coding keys and
/// stays source-compatible with the iOS companion target.
public struct LinkMessage: Codable, Sendable, Equatable {
    public var kind: Kind
    public var deviceName: String
    public var deviceID: String
    /// Timer seconds (timerStart / timerState remaining).
    public var seconds: Double?
    public var total: Double?
    public var label: String?
    public var text: String?
    public var fileName: String?
    public var fileSize: Int?
    public var chunkIndex: Int?
    public var chunkCount: Int?
    public var base64: String?
    /// 0...1 battery, nil = unknown.
    public var battery: Double?
    public var charging: Bool?
    /// Media being played on the sender (informational only).
    public var mediaTitle: String?
    public var mediaArtist: String?
    public var playing: Bool?
    /// iPhone Live Activity synchronization fields
    public var activityID: String?
    public var activityType: String?
    public var activityTitle: String?
    public var activitySubtitle: String?
    public var activityProgress: Double?
    public var activityIcon: String?
    public var activityLeadingText: String?
    public var activityTrailingText: String?
    public var activityTimestamp: Double?

    public enum Kind: String, Codable, Sendable {
        case hello
        case heartbeat
        case bye
        case timerStart
        case timerState
        case timerCancel
        case textPush
        case fileOffer
        case fileChunk
        case fileDone
        case battery
        case mediaState
        case liveActivityUpdate
        case liveActivityEnd
    }

    public init(kind: Kind, deviceName: String, deviceID: String) {
        self.kind = kind
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

/// Plaintext handshake frame carrying the session salt (public, random per
/// listener start). Both sides then derive the same AES key as
/// SHA256(salt + "#" + pairingCode).
public struct LinkSaltFrame: Codable, Sendable {
    public var v: Int
    public var salt: String
    public var deviceName: String
    public var deviceID: String

    public init(salt: String, deviceName: String, deviceID: String) {
        self.v = LinkProtocol.protocolVersion
        self.salt = salt
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

/// First encrypted frame each side sends; proves knowledge of the pairing
/// code without ever transmitting it.
public struct LinkAuthPayload: Codable, Sendable {
    public var magic: String
    public var deviceName: String
    public var deviceID: String

    public init(deviceName: String, deviceID: String) {
        self.magic = LinkProtocol.authMagic
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

public enum LinkCodec {
    public static func encode(_ message: LinkMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    public static func decode(_ data: Data) throws -> LinkMessage {
        try JSONDecoder().decode(LinkMessage.self, from: data)
    }

    /// Length-prefix a payload for stream framing.
    public static func frame(_ payload: Data) -> Data {
        var out = Data()
        out.reserveCapacity(4 + payload.count)
        let len = UInt32(payload.count)
        out.append(UInt8((len >> 24) & 0xFF))
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(contentsOf: payload)
        return out
    }

    /// Read a big-endian length prefix without assuming pointer alignment.
    public static func readLength(_ prefix: Data) -> UInt32 {
        precondition(prefix.count >= 4)
        let b0 = UInt32(prefix[prefix.startIndex])
        let b1 = UInt32(prefix[prefix.startIndex + 1])
        let b2 = UInt32(prefix[prefix.startIndex + 2])
        let b3 = UInt32(prefix[prefix.startIndex + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

/// Packs a file into an offer + chunk + done message sequence, shared by the
/// Mac and iPhone senders so both sides frame files identically.
public enum LinkChunker {
    public static func pack(data: Data, fileName: String, deviceName: String, deviceID: String) -> [LinkMessage] {
        var out: [LinkMessage] = []
        // NB: subdata(in:) rather than the Range subscript — the subscript
        // traps on some Data representations on macOS 27 beta (see RECORD).
        let chunks = stride(from: 0, to: data.count, by: LinkProtocol.fileChunkBytes).map {
            data.subdata(in: $0 ..< min($0 + LinkProtocol.fileChunkBytes, data.count))
        }
        var offer = LinkMessage(kind: .fileOffer, deviceName: deviceName, deviceID: deviceID)
        offer.fileName = fileName
        offer.fileSize = data.count
        offer.chunkCount = chunks.count
        out.append(offer)
        for (i, c) in chunks.enumerated() {
            var m = LinkMessage(kind: .fileChunk, deviceName: deviceName, deviceID: deviceID)
            m.fileName = fileName
            m.chunkIndex = i
            m.chunkCount = chunks.count
            m.base64 = Data(c).base64EncodedString()
            out.append(m)
        }
        var done = LinkMessage(kind: .fileDone, deviceName: deviceName, deviceID: deviceID)
        done.fileName = fileName
        out.append(done)
        return out
    }
}
