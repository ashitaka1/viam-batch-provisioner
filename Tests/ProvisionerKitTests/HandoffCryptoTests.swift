import Foundation
@testable import ProvisionerKit
import Testing

private struct Session {
    var nonce = HandoffNonce.random()
    var command = HandoffKeyPair()
    var app = HandoffKeyPair()
    var appNonce = HandoffNonce.random()

    func commandSide(peer: Data? = nil) throws -> HandoffSecrets {
        try HandoffSecrets(own: command, peerPublicKey: peer ?? app.publicKey, nonce: nonce,
                           commandPublicKey: command.publicKey, appPublicKey: peer ?? app.publicKey, appNonce: appNonce)
    }

    func appSide(peer: Data? = nil) throws -> HandoffSecrets {
        try HandoffSecrets(own: app, peerPublicKey: peer ?? command.publicKey, nonce: nonce,
                           commandPublicKey: peer ?? command.publicKey, appPublicKey: app.publicKey, appNonce: appNonce)
    }
}

private let payload = HandoffPayload(
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
    let middle = HandoffKeyPair()
    // The command talks to a party in the middle; the app talks to the middle too.
    let command = try session.commandSide(peer: middle.publicKey)
    let app = try session.appSide(peer: middle.publicKey)
    #expect(command.code != app.code)
    #expect(throws: HandoffError.decryptionFailed) { try app.open(command.seal(payload)) }
}

@Test func tamperedCiphertextRejected() throws {
    let session = Session()
    var sealed = try session.commandSide().seal(payload)
    sealed[sealed.count / 2] ^= 0x01
    #expect(throws: HandoffError.decryptionFailed) { try session.appSide().open(sealed) }
}

@Test func invalidPeerKeyRejected() {
    let session = Session()
    #expect(throws: HandoffError.invalidPeerKey) { try session.commandSide(peer: Data([1, 2, 3])) }
}

@Test func codeIsZeroPaddedDecimal() {
    // First four digest bytes 0x00 0x00 0x00 0x2A → 42 → "0042".
    #expect(HandoffSecrets.code(digestPrefix: [0x00, 0x00, 0x00, 0x2A]) == "0042")
    // 0xFFFFFFFF = 4294967295 → 7295.
    #expect(HandoffSecrets.code(digestPrefix: [0xFF, 0xFF, 0xFF, 0xFF]) == "7295")
}

@Test func payloadDescriptionOmitsKey() {
    #expect(!String(describing: payload).contains("s3cret"))
    #expect(!String(reflecting: payload).contains("s3cret"))
}

@Test func noncesAndKeyPairsAreFresh() {
    #expect(HandoffNonce.random() != HandoffNonce.random())
    #expect(HandoffKeyPair().publicKey != HandoffKeyPair().publicKey)
}

@Test func codeAndKeyAreBoundToTheSessionNonce() throws {
    let first = Session()
    let second = Session(nonce: .random(), command: first.command, app: first.app, appNonce: first.appNonce)
    #expect(try first.commandSide().code != second.appSide().code)
    #expect(throws: HandoffError.decryptionFailed) { try second.appSide().open(first.commandSide().seal(payload)) }
}

@Test func nonceRoundTripsThroughBase64URL() throws {
    let nonce = HandoffNonce.random()
    #expect(nonce.bytes.count == 16)
    #expect(HandoffNonce(base64URL: nonce.base64URL) == nonce)
    #expect(!nonce.base64URL.contains("+") && !nonce.base64URL.contains("/") && !nonce.base64URL.contains("="))
    #expect(HandoffNonce(base64URL: "c2hvcnQ") == nil, "a 5-byte nonce is not a nonce")
    #expect(HandoffNonce(base64URL: "AAAAAAAAAAAAAAAAAAAAAAA") == nil, "a 17-byte nonce is not a nonce")
}

// The code must depend on a value the app fixed before seeing the command's key,
// so a party answering the app can't choose a key that steers the code.

private func fixedKey(_ byte: UInt8) throws -> HandoffKeyPair {
    try HandoffKeyPair(rawPrivateKey: Data(repeating: byte, count: 32))
}

@Test func codeDependsOnAppNonce() throws {
    let command = try fixedKey(1)
    let app = try fixedKey(2)
    let nonce = try #require(HandoffNonce(base64URL: "AAAAAAAAAAAAAAAAAAAAAA"))
    func code(_ appNonce: String) throws -> String {
        try HandoffSecrets(own: command, peerPublicKey: app.publicKey, nonce: nonce, commandPublicKey: command.publicKey,
                           appPublicKey: app.publicKey, appNonce: #require(HandoffNonce(base64URL: appNonce))).code
    }
    #expect(try code("AQEBAQEBAQEBAQEBAQEBAQ") != code("AgICAgICAgICAgICAgICAg"))
}

@Test func commitmentBindsKeyAndNonce() throws {
    let key = HandoffKeyPair().publicKey
    let other = HandoffKeyPair().publicKey
    let appNonce = HandoffNonce.random()
    let commitment = HandoffCommitment.make(appPublicKey: key, appNonce: appNonce)
    #expect(HandoffCommitment.verify(commitment, appPublicKey: key, appNonce: appNonce))
    #expect(!HandoffCommitment.verify(commitment, appPublicKey: other, appNonce: appNonce), "another key")
    #expect(!HandoffCommitment.verify(commitment, appPublicKey: key, appNonce: .random()), "another nonce")
}
