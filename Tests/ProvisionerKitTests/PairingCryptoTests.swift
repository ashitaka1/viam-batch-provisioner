import Foundation
@testable import ProvisionerKit
import Testing

private struct Session {
    let nonce = PairingNonce.random()
    let command = PairingKeyPair()
    let app = PairingKeyPair()
    let appNonce = PairingNonce.random()

    func commandSide(peer: Data? = nil) throws -> PairingSecrets {
        try PairingSecrets(own: command, peerPublicKey: peer ?? app.publicKey, nonce: nonce,
                           commandPublicKey: command.publicKey, appPublicKey: peer ?? app.publicKey, appNonce: appNonce)
    }

    func appSide(peer: Data? = nil) throws -> PairingSecrets {
        try PairingSecrets(own: app, peerPublicKey: peer ?? command.publicKey, nonce: nonce,
                           commandPublicKey: peer ?? command.publicKey, appPublicKey: app.publicKey, appNonce: appNonce)
    }
}

private let payload = PairingPayload(
    orgID: "o1", orgName: "Acme", keyID: "k1", key: "s3cret", keyName: "provisioner-app studio 2026-10-31")

@Test func bothSidesDeriveSameCodeAndKey() throws {
    let session = Session()
    let command = try session.commandSide()
    let app = try session.appSide()
    #expect(command.code == app.code)
    #expect(command.code.count == 4 && command.code.allSatisfy(\.isNumber), "code \(command.code)")
    #expect(try app.open(command.seal(payload)) == payload)
}

@Test func substitutedKeyChangesCode() throws {
    let session = Session()
    let middle = PairingKeyPair()
    // The command talks to a party in the middle; the app talks to the middle too.
    let command = try session.commandSide(peer: middle.publicKey)
    let app = try session.appSide(peer: middle.publicKey)
    #expect(command.code != app.code)
    #expect(throws: PairingError.decryptionFailed) { try app.open(command.seal(payload)) }
}

@Test func tamperedCiphertextRejected() throws {
    let session = Session()
    var sealed = try session.commandSide().seal(payload)
    sealed[sealed.count / 2] ^= 0x01
    #expect(throws: PairingError.decryptionFailed) { try session.appSide().open(sealed) }
}

@Test func invalidPeerKeyRejected() {
    let session = Session()
    #expect(throws: PairingError.invalidPeerKey) { try session.commandSide(peer: Data([1, 2, 3])) }
}

@Test func codeIsZeroPaddedDecimal() {
    // First four digest bytes 0x00 0x00 0x00 0x2A → 42 → "0042".
    #expect(PairingSecrets.code(digestPrefix: [0x00, 0x00, 0x00, 0x2A]) == "0042")
    // 0xFFFFFFFF = 4294967295 → 7295.
    #expect(PairingSecrets.code(digestPrefix: [0xFF, 0xFF, 0xFF, 0xFF]) == "7295")
}

@Test func payloadDescriptionOmitsKey() {
    #expect(!String(describing: payload).contains("s3cret"))
    #expect(!String(reflecting: payload).contains("s3cret"))
}

@Test func nonceRoundTripsThroughBase64URL() throws {
    let nonce = PairingNonce.random()
    #expect(nonce.bytes.count == 16)
    #expect(PairingNonce(base64URL: nonce.base64URL) == nonce)
    #expect(!nonce.base64URL.contains("+") && !nonce.base64URL.contains("/") && !nonce.base64URL.contains("="))
    #expect(PairingNonce(base64URL: "c2hvcnQ") == nil, "a 5-byte nonce is not a nonce")
    #expect(PairingNonce(base64URL: "AAAAAAAAAAAAAAAAAAAAAAA") == nil, "a 17-byte nonce is not a nonce")
}

// The code must depend on a value the app fixed before seeing the command's key,
// so a party answering the app can't choose a key that steers the code.

private func fixedKey(_ byte: UInt8) throws -> PairingKeyPair {
    try PairingKeyPair(rawPrivateKey: Data(repeating: byte, count: 32))
}

@Test func codeDependsOnAppNonce() throws {
    let command = try fixedKey(1)
    let app = try fixedKey(2)
    let nonce = try #require(PairingNonce(base64URL: "AAAAAAAAAAAAAAAAAAAAAA"))
    func code(_ appNonce: String) throws -> String {
        try PairingSecrets(own: command, peerPublicKey: app.publicKey, nonce: nonce, commandPublicKey: command.publicKey,
                           appPublicKey: app.publicKey, appNonce: #require(PairingNonce(base64URL: appNonce))).code
    }
    #expect(try code("AQEBAQEBAQEBAQEBAQEBAQ") != code("AgICAgICAgICAgICAgICAg"))
}

@Test func commitmentBindsKeyAndNonce() throws {
    let key = PairingKeyPair().publicKey
    let other = PairingKeyPair().publicKey
    let appNonce = PairingNonce.random()
    let commitment = PairingCommitment.make(appPublicKey: key, appNonce: appNonce)
    #expect(PairingCommitment.verify(commitment, appPublicKey: key, appNonce: appNonce))
    #expect(!PairingCommitment.verify(commitment, appPublicKey: other, appNonce: appNonce), "another key")
    #expect(!PairingCommitment.verify(commitment, appPublicKey: key, appNonce: .random()), "another nonce")
}

@Test func helloCarriesNoKeyMaterial() throws {
    let hello = PairingHello(nonce: "n", commitment: "c")
    let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
    #expect(Set(fields.keys) == ["nonce", "commitment"], "hello fields \(fields.keys.sorted())")
}
