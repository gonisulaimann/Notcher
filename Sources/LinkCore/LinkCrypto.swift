import CryptoKit
import Foundation

/// App-layer encryption for Notcher Link. The pairing code never leaves the
/// device; both sides derive an identical 256-bit key from public salt +
/// secret code, then seal every protocol frame with AES-GCM.
///
/// Honest limitation (also stated in docs): the salt is exchanged in clear
/// on the LAN during the handshake, so secrecy rests on the 6-digit code
/// (~20 bits). That is appropriate for a same-room, same-Wi-Fi pairing UX
/// (same trade-off as AirPlay codes / Wi-Fi WPS), but it is NOT a substitute
/// for certificate-pinned TLS against an active LAN attacker. A future
/// version should upgrade the handshake to SPAKE2/PAKE.
public enum LinkCrypto {
    public static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    public static func deriveKey(salt: String, code: String) -> SymmetricKey {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = Data((salt + "#" + normalized).utf8)
        let digest = SHA256.hash(data: input)
        return SymmetricKey(data: digest)
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw LinkCryptoError.sealFailed }
        return combined
    }

    public static func open(_ combined: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }

    public static func encodeAuth(deviceName: String, deviceID: String, key: SymmetricKey) throws -> Data {
        let payload = try JSONEncoder().encode(LinkAuthPayload(deviceName: deviceName, deviceID: deviceID))
        return try seal(payload, key: key)
    }

    public static func verifyAuth(_ plaintext: Data) throws -> LinkAuthPayload {
        let auth = try JSONDecoder().decode(LinkAuthPayload.self, from: plaintext)
        guard auth.magic == LinkProtocol.authMagic else { throw LinkCryptoError.authMismatch }
        return auth
    }
}

public enum LinkCryptoError: Error {
    case sealFailed
    case authMismatch
}
