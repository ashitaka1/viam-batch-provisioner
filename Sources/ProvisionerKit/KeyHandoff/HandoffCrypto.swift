import CryptoKit
public import Foundation

public enum HandoffError: Error, Equatable, Sendable {
    case invalidPeerKey
    case decryptionFailed
    case invalidLink
}

/// 16 random bytes that name one handoff session and salt its key derivation.
public struct HandoffNonce: Sendable, Hashable, Codable {
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
public struct HandoffKeyPair: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = .init() }

    init(rawPrivateKey: Data) throws { privateKey = try .init(rawRepresentation: rawPrivateKey) }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
}

/// The app's opening move: a hash binding its public key and a fresh nonce,
/// sent before it sees the command's key and revealed after. A party answering
/// the app must pick its key without knowing the app's, so it can't search for
/// a key that makes the codes match (Bluetooth Secure Simple Pairing's numeric
/// comparison uses the same commit-then-reveal step).
public enum HandoffCommitment {
    public static func make(appPublicKey: Data, appNonce: HandoffNonce) -> Data {
        Data(SHA256.hash(data: HandoffSecrets.label + Data("commit".utf8) + appPublicKey + appNonce.bytes))
    }

    public static func verify(_ commitment: Data, appPublicKey: Data, appNonce: HandoffNonce) -> Bool {
        make(appPublicKey: appPublicKey, appNonce: appNonce) == commitment
    }
}

/// What both sides derive once they hold each other's public keys and the app's
/// revealed nonce: the code the operator compares and the key that seals the
/// payload. A party in the middle holds different keys with each side, and the
/// commitment stops it choosing keys that make the two codes agree.
public struct HandoffSecrets: Sendable {
    static let label = Data("viam-provisioner-handoff-v1".utf8)

    public let code: String
    private let key: SymmetricKey

    public init(own: HandoffKeyPair, peerPublicKey: Data, nonce: HandoffNonce,
                commandPublicKey: Data, appPublicKey: Data, appNonce: HandoffNonce) throws {
        let peer: Curve25519.KeyAgreement.PublicKey
        let shared: SharedSecret
        do {
            peer = try .init(rawRepresentation: peerPublicKey)
            shared = try own.privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw HandoffError.invalidPeerKey
        }
        let transcript = Self.label + nonce.bytes + commandPublicKey + appPublicKey + appNonce.bytes
        code = Self.code(digestPrefix: Array(SHA256.hash(data: transcript).prefix(4)))
        key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: nonce.bytes, sharedInfo: transcript + Data("key".utf8), outputByteCount: 32)
    }

    static func code(digestPrefix: [UInt8]) -> String {
        let value = digestPrefix.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10_000
        return String(format: "%04u", value)
    }

    public func seal(_ payload: HandoffPayload) throws -> Data {
        try ChaChaPoly.seal(JSONEncoder().encode(payload), using: key).combined
    }

    public func open(_ sealed: Data) throws -> HandoffPayload {
        do {
            let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
            return try JSONDecoder().decode(HandoffPayload.self, from: plaintext)
        } catch {
            throw HandoffError.decryptionFailed
        }
    }
}
