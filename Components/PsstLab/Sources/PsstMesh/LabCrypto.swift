// PSST (L1): psst lab end-to-end encryption of LoRa direct messages (on top of whatever Meshtastic does).
//
// Keys     every psst lab user has a static X25519 key pair (Keychain on iOS). Peers learn each other's public key and
//          LoRa node number from a PeerCard sent in an end-to-end encrypted psst (Matrix) chat or scanned as a QR code.
// Key      per direction: K(A→B) = HKDF-SHA256(X25519(a, B), salt "psst-lab/lora/v1",
//          info "psst-lab/lora/v1 msg" ‖ pubA ‖ pubB ‖ nodeA ‖ nodeB), 32 bytes. Separate keys per direction, so the two
//          sides never use the same (key, nonce) pair even with equal counters.
// Cipher   ChaCha20-Poly1305 (CryptoKit). Nonce = 8 zero bytes ‖ counter (UInt32 BE). The counter is per (sender, peer),
//          strictly increasing and persisted BEFORE sending → a nonce is never reused with the same key.
// AAD      the 6-byte header without the chunk index (magic, counter, chunk count) ‖ sender node ‖ recipient node.
// Frame    [0] 0xB1 magic/version  [1..4] counter BE  [5] chunk index << 4 | (chunk count − 1)  [6...] ciphertext part.
//          The sealed box (ciphertext ‖ 16-byte tag) of the whole message is split into ≤ 16 parts; the receiver puts the
//          parts together by (sender node, counter) and opens the box only when all parts are there.
// Plain    [0] content type (0x01 = UTF-8 text)  [1...] UTF-8 text.
// Replay   the receiver keeps, per peer, the highest counter + a 64-message sliding window; a counter seen before or
//          older than the window is rejected. Only a message whose tag verifies is marked as seen.
// Sender   authenticity comes from the static-static X25519 secret: only the holder of A's or B's private key can make
//          a tag that verifies, and the key direction fixes who sent it. The Meshtastic `from` field must also match the
//          node in the peer's card.
import CryptoKit
import Foundation

public enum LabCryptoError: Error, Equatable {
    case notAFrame
    case badFrame
    case messageTooLong(maxBytes: Int)
    case authenticationFailed
    case replayed(counter: UInt32)
    case unknownContentType
}

public enum LabFormat {
    public static let magic: UInt8 = 0xB1
    public static let headerLength = 6
    public static let tagLength = 16
    public static let maxChunks = 16
    /// Bytes of one frame (header + part). 200 + Meshtastic Data overhead (≈ 8) + PKI overhead (12) + 16-byte LoRa header
    /// stays below the 255-byte LoRa frame (DECISIONS L1-07).
    public static let maxFrameBytes = 200
    public static var maxPartBytes: Int { maxFrameBytes - headerLength }
    /// Max UTF-8 bytes of one encrypted message the app allows (8 frames, ~8 × 1–2 s of airtime on LongFast).
    public static let appMaxChunks = 8
    public static func maxTextBytes(chunks: Int = appMaxChunks) -> Int { chunks * maxPartBytes - tagLength - 1 }
    static let salt = Data("psst-lab/lora/v1".utf8)
    static let info = Data("psst-lab/lora/v1 msg".utf8)
}

// MARK: - Identity

public struct LabIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }
    public init(rawPrivateKey: Data) throws { privateKey = try .init(rawRepresentation: rawPrivateKey) }
    public var rawPrivateKey: Data { privateKey.rawRepresentation }

    /// Short human-comparable fingerprint of a public key: first 8 bytes of SHA-256, hex in 4 groups.
    public static func fingerprint(_ publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map {
            let s = hex.index(hex.startIndex, offsetBy: $0)
            return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

// MARK: - Peer card (key + "Matrix user ↔ LoRa node" binding)

/// What two psst lab users exchange: public key, LoRa node and (optionally) the Matrix user ID.
/// Text form `psstlab1:<base64url>` — used both in the Matrix message and in the QR code.
public struct PeerCard: Codable, Equatable, Sendable {
    public var nodeNum: UInt32
    public var publicKey: Data
    public var matrixUserID: String?
    public var name: String

    public static let prefix = "psstlab1:"

    public init(nodeNum: UInt32, publicKey: Data, matrixUserID: String?, name: String) {
        self.nodeNum = nodeNum
        self.publicKey = publicKey
        self.matrixUserID = matrixUserID
        self.name = name
    }

    public var encoded: String {
        var d = Data([1])
        d.appendBE(nodeNum)
        d.append(publicKey)
        let mx = Data((matrixUserID ?? "").utf8.prefix(255))
        d.append(UInt8(mx.count)); d.append(mx)
        let nm = Data(String(name.prefix(60)).utf8.prefix(255))
        d.append(UInt8(nm.count)); d.append(nm)
        return Self.prefix + d.base64URLEncodedString()
    }

    /// Finds and parses the first `psstlab1:` token in a text (a Matrix message body or a scanned QR code).
    public static func find(in text: String) -> PeerCard? {
        guard let r = text.range(of: prefix) else { return nil }
        let token = text[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let d = Data(base64URLEncoded: String(token)), d.count >= 1 + 4 + 32 + 2, d[d.startIndex] == 1 else { return nil }
        var i = d.startIndex + 1
        let node = d.readBE(at: i); i += 4
        let pub = Data(d[i..<(i + 32)]); i += 32
        guard i < d.endIndex else { return nil }
        let mxLen = Int(d[i]); i += 1
        guard i + mxLen < d.endIndex else { return nil }
        let mx = String(decoding: d[i..<(i + mxLen)], as: UTF8.self); i += mxLen
        let nmLen = Int(d[i]); i += 1
        guard i + nmLen <= d.endIndex else { return nil }
        let nm = String(decoding: d[i..<(i + nmLen)], as: UTF8.self)
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)) != nil, node != 0 else { return nil }
        return PeerCard(nodeNum: node, publicKey: pub, matrixUserID: mx.isEmpty ? nil : mx, name: nm)
    }
}

// MARK: - Replay window

public struct ReplayWindow: Codable, Equatable, Sendable {
    public private(set) var highest: UInt32 = 0
    public private(set) var bitmap: UInt64 = 0 // bit i = counter (highest − i) seen
    public static let size: UInt32 = 64

    public init() {}

    public func isFresh(_ c: UInt32) -> Bool {
        if c == 0 { return false } // counters start at 1
        if c > highest { return true }
        let diff = highest - c
        if diff >= Self.size { return false }
        return bitmap & (UInt64(1) << UInt64(diff)) == 0
    }

    public mutating func mark(_ c: UInt32) {
        if c > highest {
            let shift = c - highest
            bitmap = shift >= Self.size ? 0 : bitmap << UInt64(shift)
            bitmap |= 1
            highest = c
        } else {
            bitmap |= UInt64(1) << UInt64(highest - c)
        }
    }
}

// MARK: - Seal / open

public enum LabCrypto {
    public static func directionKey(identity: LabIdentity, senderPub: Data, senderNode: UInt32,
                                    recipientPub: Data, recipientNode: UInt32, peerPub: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
        let shared = try identity.privateKey.sharedSecretFromKeyAgreement(with: peer)
        var info = LabFormat.info
        info.append(senderPub); info.append(recipientPub)
        info.appendBE(senderNode); info.appendBE(recipientNode)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: LabFormat.salt, sharedInfo: info, outputByteCount: 32)
    }

    static func nonce(_ counter: UInt32) -> ChaChaPoly.Nonce {
        var n = Data(count: 8)
        n.appendBE(counter)
        return try! ChaChaPoly.Nonce(data: n) // 12 bytes, cannot fail
    }

    static func aad(counter: UInt32, chunks: Int, senderNode: UInt32, recipientNode: UInt32) -> Data {
        var a = Data([LabFormat.magic])
        a.appendBE(counter)
        a.append(UInt8(chunks - 1))
        a.appendBE(senderNode); a.appendBE(recipientNode)
        return a
    }

    /// Encrypts `text` for the peer and returns the LoRa frames (each ≤ LabFormat.maxFrameBytes).
    public static func seal(text: String, counter: UInt32, identity: LabIdentity, myNode: UInt32,
                            peer: PeerCard, maxChunks: Int = LabFormat.appMaxChunks) throws -> [Data] {
        precondition(counter > 0)
        var plain = Data([0x01])
        plain.append(Data(text.utf8))
        let sealedLength = plain.count + LabFormat.tagLength
        let chunks = max(1, Int((Double(sealedLength) / Double(LabFormat.maxPartBytes)).rounded(.up)))
        guard chunks <= min(maxChunks, LabFormat.maxChunks) else {
            throw LabCryptoError.messageTooLong(maxBytes: LabFormat.maxTextBytes(chunks: min(maxChunks, LabFormat.maxChunks)))
        }
        let key = try directionKey(identity: identity, senderPub: identity.publicKey, senderNode: myNode,
                                   recipientPub: peer.publicKey, recipientNode: peer.nodeNum, peerPub: peer.publicKey)
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce(counter),
                                      authenticating: aad(counter: counter, chunks: chunks, senderNode: myNode, recipientNode: peer.nodeNum))
        var body = box.ciphertext
        body.append(box.tag)
        var frames: [Data] = []
        for i in 0..<chunks {
            let lo = body.startIndex + i * LabFormat.maxPartBytes
            let hi = min(lo + LabFormat.maxPartBytes, body.endIndex)
            var f = Data([LabFormat.magic])
            f.appendBE(counter)
            f.append(UInt8(i << 4 | (chunks - 1)))
            f.append(body[lo..<hi])
            frames.append(f)
        }
        return frames
    }

    /// Opens a complete message (all parts, in order). Replay check is the caller's job (see LabInbox).
    public static func open(body: Data, counter: UInt32, chunks: Int, identity: LabIdentity, myNode: UInt32,
                            peer: PeerCard) throws -> String {
        guard body.count > LabFormat.tagLength else { throw LabCryptoError.badFrame }
        let key = try directionKey(identity: identity, senderPub: peer.publicKey, senderNode: peer.nodeNum,
                                   recipientPub: identity.publicKey, recipientNode: myNode, peerPub: peer.publicKey)
        let ct = body.prefix(body.count - LabFormat.tagLength)
        let tag = body.suffix(LabFormat.tagLength)
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: ct, tag: tag)
            plain = try ChaChaPoly.open(box, using: key,
                                        authenticating: aad(counter: counter, chunks: chunks, senderNode: peer.nodeNum, recipientNode: myNode))
        } catch {
            throw LabCryptoError.authenticationFailed
        }
        guard plain.first == 0x01 else { throw LabCryptoError.unknownContentType }
        return String(decoding: plain.dropFirst(), as: UTF8.self)
    }
}

// MARK: - Frame header

public struct LabFrame: Equatable, Sendable {
    public let counter: UInt32
    public let index: Int
    public let count: Int
    public let part: Data

    public static func isLabFrame(_ d: Data) -> Bool { d.first == LabFormat.magic }

    public init(_ d: Data) throws {
        guard d.first == LabFormat.magic else { throw LabCryptoError.notAFrame }
        guard d.count > LabFormat.headerLength else { throw LabCryptoError.badFrame }
        let s = d.startIndex
        counter = d.readBE(at: s + 1)
        index = Int(d[s + 5] >> 4)
        count = Int(d[s + 5] & 0x0F) + 1
        part = Data(d[(s + LabFormat.headerLength)...])
        guard index < count, counter > 0 else { throw LabCryptoError.badFrame }
    }
}

// MARK: - Reassembly + replay protection

/// Collects frames from peers, opens complete messages, enforces the replay window.
public struct LabInbox: Sendable {
    struct Key: Hashable, Sendable { let node: UInt32; let counter: UInt32 }
    struct Partial: Sendable { var count: Int; var parts: [Int: Data]; var firstSeen: Date }
    private var partials: [Key: Partial] = [:]
    public var windows: [UInt32: ReplayWindow] // per peer node
    public static let partialTimeout: TimeInterval = 15 * 60

    public init(windows: [UInt32: ReplayWindow] = [:]) { self.windows = windows }

    public enum Result: Equatable, Sendable {
        case incomplete(received: Int, of: Int)
        case message(text: String, counter: UInt32, chunks: Int)
        case duplicateFrame
    }

    public mutating func receive(frame data: Data, from peer: PeerCard, identity: LabIdentity, myNode: UInt32,
                                 now: Date = Date()) throws -> Result {
        let f = try LabFrame(data)
        var w = windows[peer.nodeNum] ?? ReplayWindow()
        guard w.isFresh(f.counter) else { throw LabCryptoError.replayed(counter: f.counter) }
        partials = partials.filter { now.timeIntervalSince($0.value.firstSeen) < Self.partialTimeout }
        let k = Key(node: peer.nodeNum, counter: f.counter)
        var p = partials[k] ?? Partial(count: f.count, parts: [:], firstSeen: now)
        guard p.count == f.count else { throw LabCryptoError.badFrame }
        if p.parts[f.index] != nil { return .duplicateFrame }
        p.parts[f.index] = f.part
        guard p.parts.count == p.count else {
            partials[k] = p
            return .incomplete(received: p.parts.count, of: p.count)
        }
        partials[k] = nil
        var body = Data()
        for i in 0..<p.count { body.append(p.parts[i]!) }
        let text = try LabCrypto.open(body: body, counter: f.counter, chunks: p.count, identity: identity, myNode: myNode, peer: peer)
        w.mark(f.counter)
        windows[peer.nodeNum] = w
        return .message(text: text, counter: f.counter, chunks: p.count)
    }
}

// MARK: - Helpers

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    func readBE(at i: Index) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    public func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        self.init(base64Encoded: b)
    }
}
