public import Foundation

/// The credential the command hands the app, sealed with the session key.
public struct PairingPayload: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var orgID: String
    public var orgName: String
    public var keyID: String
    public var key: String
    public var keyName: String

    public init(orgID: String, orgName: String, keyID: String, key: String, keyName: String) {
        self.orgID = orgID
        self.orgName = orgName
        self.keyID = keyID
        self.key = key
        self.keyName = keyName
    }

    public var description: String { "PairingPayload(org: \(orgName) \(orgID), key: \(keyName) \(keyID))" }
    public var debugDescription: String { description }
}

// Wire messages. Public keys and sealed bytes are standard base64.

/// App → command: the first request of a session.
public struct PairingHello: Codable, Sendable, Equatable {
    public var nonce: String
    public var appPublicKey: String

    public init(nonce: String, appPublicKey: String) {
        self.nonce = nonce
        self.appPublicKey = appPublicKey
    }
}

/// Command → app: its public key and the org being paired.
public struct PairingHelloReply: Codable, Sendable, Equatable {
    public var commandPublicKey: String
    public var orgID: String
    public var orgName: String

    public init(commandPublicKey: String, orgID: String, orgName: String) {
        self.commandPublicKey = commandPublicKey
        self.orgID = orgID
        self.orgName = orgName
    }
}

/// App → command: identifies the session on every request after hello.
public struct PairingSessionRequest: Codable, Sendable, Equatable {
    public var nonce: String
    public var appPublicKey: String

    public init(nonce: String, appPublicKey: String) {
        self.nonce = nonce
        self.appPublicKey = appPublicKey
    }
}

/// Command → app: the payload, once the operator confirms the code.
public struct PairingSealed: Codable, Sendable, Equatable {
    public var sealed: String

    public init(sealed: String) { self.sealed = sealed }
}

/// App → command: whether the app kept the key.
public struct PairingResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case stored
        case rejected
    }

    public var nonce: String
    public var appPublicKey: String
    public var outcome: Outcome
    public var message: String?

    public init(nonce: String, appPublicKey: String, outcome: Outcome, message: String?) {
        self.nonce = nonce
        self.appPublicKey = appPublicKey
        self.outcome = outcome
        self.message = message
    }
}
