// PSST (L1): data model of the psst lab LoRa section (nodes, conversations, messages, peers) + persistence.
import Foundation
import Security

public enum Conversation: Hashable, Codable, Sendable {
    case channel(Int)       // Meshtastic channel index (0 = primary), broadcast
    case direct(UInt32)     // a node
}

/// Who protects the message content on the air — shown on every message bubble.
public enum MessageSecurity: String, Codable, Sendable {
    case psstE2E            // our X25519 + ChaCha20-Poly1305 (only the two psst lab users can read it)
    case meshtasticPKI      // Meshtastic DM encrypted with the nodes' X25519 keys (AES-CCM); the radios can read it
    case meshtasticChannel  // Meshtastic channel key (AES-CTR, shared by everybody with the channel key)
    case meshtasticDefaultKey // channel with the published default key "AQ==" — effectively readable by anyone
    case none               // channel without encryption
}

public enum DeliveryState: Codable, Equatable, Sendable {
    case queued             // handed to the radio
    case sent               // radio accepted it / it was transmitted (implicit ACK: a neighbour relayed it)
    case delivered          // ACK from the destination node (direct messages)
    case failed(String)     // routing error / timeout / no radio

    public var isFinal: Bool {
        switch self { case .delivered, .failed: true; default: false }
    }
}

public struct LoRaMessage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var conversation: Conversation
    public var outgoing: Bool
    public var fromNode: UInt32
    public var text: String
    public var date: Date
    public var security: MessageSecurity
    public var state: DeliveryState
    /// Meshtastic packet IDs of this message (several for a chunked psst E2E message) and which of them are ACKed.
    public var packetIDs: [UInt32]
    public var ackedPacketIDs: [UInt32]
    public var relayedPacketIDs: [UInt32]
    public var chunks: Int
    public var rxSnr: Float?
    public var rxRssi: Int32?
    public var hops: Int?
    public var lastActivity: Date?

    public init(id: UUID = UUID(), conversation: Conversation, outgoing: Bool, fromNode: UInt32, text: String,
                date: Date = Date(), security: MessageSecurity, state: DeliveryState, packetIDs: [UInt32] = [],
                chunks: Int = 1) {
        self.id = id
        self.conversation = conversation
        self.outgoing = outgoing
        self.fromNode = fromNode
        self.text = text
        self.date = date
        self.security = security
        self.state = state
        self.packetIDs = packetIDs
        ackedPacketIDs = []
        relayedPacketIDs = []
        self.chunks = chunks
    }
}

public struct MeshNode: Codable, Identifiable, Equatable, Sendable {
    public var num: UInt32
    public var id: UInt32 { num }
    public var userID: String          // "!a1b2c3d4"
    public var longName: String
    public var shortName: String
    public var hwModel: String
    public var publicKey: Data?        // Meshtastic PKI key of the node (not the psst lab key)
    public var lastHeard: Date?
    public var snr: Float?
    public var rssi: Int32?
    public var hopsAway: Int?
    public var batteryLevel: Int?      // 0–100, 101 = powered
    public var voltage: Float?
    public var viaMqtt: Bool

    public init(num: UInt32) {
        self.num = num
        userID = MeshNode.userID(num)
        longName = ""
        shortName = ""
        hwModel = ""
        viaMqtt = false
    }

    public static func userID(_ num: UInt32) -> String { String(format: "!%08x", num) }
    public var displayName: String { longName.isEmpty ? userID : longName }
}

/// A psst lab contact whose key + LoRa node we know (from the psst chat or a QR code).
public struct LabPeer: Codable, Identifiable, Equatable, Sendable {
    public var card: PeerCard
    public var id: UInt32 { card.nodeNum }
    public var source: String          // "matrix" | "qr"
    public var linkedAt: Date
    public var sendCounter: UInt32     // last counter used for messages TO this peer
}

public struct ChannelInfo: Codable, Equatable, Sendable, Identifiable {
    public var index: Int
    public var id: Int { index }
    public var name: String
    public var role: String            // PRIMARY / SECONDARY
    public var pskLength: Int          // 0 none, 1 default-key alias, 16 AES-128, 32 AES-256
    public var security: MessageSecurity {
        switch pskLength {
        case 0: .none
        case 1: .meshtasticDefaultKey  // 1-byte PSK = index of the well-known default key (published)
        default: .meshtasticChannel
        }
    }
}

// MARK: - Persistence

/// Everything the LoRa section keeps between launches (messages, peers, counters, replay windows, last device).
public struct LabState: Codable, Sendable {
    public var messages: [LoRaMessage] = []
    public var peers: [UInt32: LabPeer] = [:]
    public var replayWindows: [UInt32: ReplayWindow] = [:]
    public var nodes: [UInt32: MeshNode] = [:]
    public var myNodeNum: UInt32?
    public var lastDeviceID: String?
    public var lastDeviceName: String?
    /// Matrix user → Matrix-sent card we already sent (for UI: "your card was sent")
    public var cardsSentTo: [String: Date] = [:]
    public init() {}
}

public final class LabStateStore: @unchecked Sendable {
    public let url: URL
    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("lora-state.json")
    }

    public func load() -> LabState {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(LabState.self, from: d) else { return LabState() }
        return s
    }

    public func save(_ s: LabState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        #if os(iOS)
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? d.write(to: url, options: .atomic)
        #endif
    }
}

// MARK: - Private key storage

public protocol LabKeyStore: Sendable {
    func loadOrCreateIdentity() throws -> LabIdentity
}

/// Keychain (this device only, after first unlock, never synced to iCloud).
public struct KeychainKeyStore: LabKeyStore {
    public let service: String
    public let account = "lora-x25519"
    public init(service: String) { self.service = service }

    public func loadOrCreateIdentity() throws -> LabIdentity {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return try LabIdentity(rawPrivateKey: d)
        }
        let id = LabIdentity()
        q[kSecReturnData as String] = nil
        q[kSecValueData as String] = id.rawPrivateKey
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        return id
    }
}

/// File key store for the macOS test tool (0600 file).
public struct FileKeyStore: LabKeyStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func loadOrCreateIdentity() throws -> LabIdentity {
        if let d = try? Data(contentsOf: url) { return try LabIdentity(rawPrivateKey: d) }
        let id = LabIdentity()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: id.rawPrivateKey, attributes: [.posixPermissions: 0o600])
        return id
    }
}
