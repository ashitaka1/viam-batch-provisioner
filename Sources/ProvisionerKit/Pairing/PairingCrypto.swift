import CryptoKit
public import Foundation

public enum PairingError: Error, Equatable, Sendable {
    case invalidPeerKey
    case decryptionFailed
    case invalidLink
}

/// 16 random bytes that name one pairing session and salt its key derivation.
public struct PairingNonce: Sendable, Hashable, Codable {
    public let bytes: Data

    public static func random() -> Self {
        Self(unchecked: Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }))
    }

    private init(unchecked bytes: Data) { self.bytes = bytes }

    public init?(base64URL: String) {
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public var base64URL: String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An ephemeral X25519 key pair, one per side per session.
public struct PairingKeyPair: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = .init() }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
}

/// What both sides derive once they hold each other's public keys: the code the
/// operator compares and the key that seals the payload. A party in the middle
/// holds different keys with each side, so the two codes differ.
public struct PairingSecrets: Sendable {
    static let label = Data("viam-provisioner-pair-v1".utf8)

    public let code: String
    private let key: SymmetricKey

    public init(own: PairingKeyPair, peerPublicKey: Data, nonce: PairingNonce,
                commandPublicKey: Data, appPublicKey: Data) throws {
        let peer: Curve25519.KeyAgreement.PublicKey
        let shared: SharedSecret
        do {
            peer = try .init(rawRepresentation: peerPublicKey)
            shared = try own.privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw PairingError.invalidPeerKey
        }
        let transcript = Self.label + nonce.bytes + commandPublicKey + appPublicKey
        code = Self.code(digestPrefix: Array(SHA256.hash(data: transcript).prefix(4)))
        key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: nonce.bytes, sharedInfo: transcript + Data("key".utf8), outputByteCount: 32)
    }

    static func code(digestPrefix: [UInt8]) -> String {
        let value = digestPrefix.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10_000
        return String(format: "%04u", value)
    }

    public func seal(_ payload: PairingPayload) throws -> Data {
        try ChaChaPoly.seal(JSONEncoder().encode(payload), using: key).combined
    }

    public func open(_ sealed: Data) throws -> PairingPayload {
        do {
            let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
            return try JSONDecoder().decode(PairingPayload.self, from: plaintext)
        } catch {
            throw PairingError.decryptionFailed
        }
    }
}
