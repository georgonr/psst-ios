// PSST (D99): shared iOS ↔ Android test vectors for the psst LoRa E2E format (TestVectors/psst-lora-vectors-v1.json).
// The same JSON is checked by the Android unit tests; both sides must produce byte-identical frames.
// Regenerate (only when the format changes on purpose): PSST_WRITE_VECTORS=1 swift test --filter VectorTests
import CryptoKit
import Foundation
@testable import PsstMesh
import Testing

struct VectorFile: Codable, Equatable {
    struct Identity: Codable, Equatable { var privateKey: String; var publicKey: String; var node: UInt32 }
    struct Message: Codable, Equatable { var from: String; var to: String; var counter: UInt32; var text: String; var frames: [String] }
    struct Card: Codable, Equatable { var node: UInt32; var publicKey: String; var matrixUserID: String?; var name: String; var encoded: String }
    struct ReplayStep: Codable, Equatable { var counter: UInt32; var accept: Bool }
    struct Tamper: Codable, Equatable { var description: String; var frames: [String] }
    var format: String
    var notes: String
    var identities: [String: Identity]
    var directionKeys: [String: String]
    var messages: [Message]
    var cards: [Card]
    var replay: [ReplayStep]
    var tampered: [Tamper]
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init(hex: String) { self.init(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)! }) }
}

func makeVectors() throws -> VectorFile {
    let a = try LabIdentity(rawPrivateKey: Data((1...32).map { UInt8($0) }))
    let b = try LabIdentity(rawPrivateKey: Data((33...64).map { UInt8($0) }))
    let nodeA: UInt32 = 0xBD46_0DF0, nodeB: UInt32 = 0xEA25_1718
    let ids = ["a": (a, nodeA), "b": (b, nodeB)]
    func card(_ k: String, mx: String?, name: String) -> PeerCard { PeerCard(nodeNum: ids[k]!.1, publicKey: ids[k]!.0.publicKey, matrixUserID: mx, name: name) }
    let cardA = card("a", mx: "@alica:psst.pro", name: "Alica"), cardB = card("b", mx: "@boris:psst.pro", name: "Boris Čierny")
    func key(_ from: String, _ to: String) throws -> String {
        let (f, fn) = ids[from]!, (t, tn) = ids[to]!
        return try LabCrypto.directionKey(identity: f, senderPub: f.publicKey, senderNode: fn, recipientPub: t.publicKey,
                                          recipientNode: tn, peerPub: t.publicKey).withUnsafeBytes { Data($0) }.hex
    }
    var msgs: [VectorFile.Message] = []
    func add(_ from: String, _ to: String, _ c: UInt32, _ text: String) throws {
        let peer = to == "a" ? cardA : cardB
        let frames = try LabCrypto.seal(text: text, counter: c, identity: ids[from]!.0, myNode: ids[from]!.1, peer: peer, maxChunks: 16)
        msgs.append(.init(from: from, to: to, counter: c, text: text, frames: frames.map(\.hex)))
    }
    try add("a", "b", 1, "Ahoj")
    try add("b", "a", 1, "Ahoj aj tebe 👋")
    try add("a", "b", 2, "Príliš žltučký kôň úpel ďábelské ódy — " + String(repeating: "LoRa ", count: 60)) // multi-frame
    try add("a", "b", 3, String(repeating: "x", count: LabFormat.maxTextBytes())) // 8 frames, max app length
    try add("b", "a", 70000, "") // empty text is allowed by the format (apps refuse to send it)
    var t1 = Data(hex: msgs[0].frames[0]); t1[8] ^= 0x01
    var t2 = Data(hex: msgs[0].frames[0]); t2[2] ^= 0x01
    var t3 = msgs[2].frames.map { Data(hex: $0) }; t3[1][t3[1].count - 1] ^= 0x80
    return VectorFile(
        format: "psst-lora-e2e-v1",
        notes: "X25519 private keys are raw 32 bytes (clamped by the X25519 function). Frames are LoRa payloads of Meshtastic PRIVATE_APP (256). directionKeys[\"a->b\"] = HKDF-SHA256(X25519(a,B), salt \"psst-lab/lora/v1\", info \"psst-lab/lora/v1 msg\"||pubA||pubB||nodeA BE||nodeB BE). See DECISIONS L1-09.",
        identities: ["a": .init(privateKey: a.rawPrivateKey.hex, publicKey: a.publicKey.hex, node: nodeA),
                     "b": .init(privateKey: b.rawPrivateKey.hex, publicKey: b.publicKey.hex, node: nodeB)],
        directionKeys: ["a->b": try key("a", "b"), "b->a": try key("b", "a")],
        messages: msgs,
        cards: [cardA, cardB, PeerCard(nodeNum: 1, publicKey: b.publicKey, matrixUserID: nil, name: "")].map {
            .init(node: $0.nodeNum, publicKey: $0.publicKey.hex, matrixUserID: $0.matrixUserID, name: $0.name, encoded: $0.encoded) },
        replay: [(10, true), (9, true), (100, true), (30, false), (100, false), (40, true), (37, true), (37, false), (101, true)].map { .init(counter: $0.0, accept: $0.1) },
        tampered: [.init(description: "a->b counter 1, ciphertext byte 8 flipped", frames: [t1.hex]),
                   .init(description: "a->b counter 1, counter byte 2 flipped (nonce + AAD)", frames: [t2.hex]),
                   .init(description: "a->b counter 2, last byte of frame 2 (tag) flipped", frames: t3.map(\.hex))])
}

@Suite struct VectorTests {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestVectors/psst-lora-vectors-v1.json")

    @Test func vectorsMatchImplementation() throws {
        let v = try makeVectors()
        if ProcessInfo.processInfo.environment["PSST_WRITE_VECTORS"] == "1" {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(v).write(to: Self.url)
        }
        let file = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: Self.url))
        #expect(file == v)
    }

    @Test func vectorsDecryptAndReplay() throws {
        let f = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: Self.url))
        func id(_ k: String) throws -> LabIdentity { try LabIdentity(rawPrivateKey: Data(hex: f.identities[k]!.privateKey)) }
        func card(_ k: String) -> PeerCard { PeerCard(nodeNum: f.identities[k]!.node, publicKey: Data(hex: f.identities[k]!.publicKey), matrixUserID: nil, name: k) }
        for k in ["a", "b"] { #expect(try id(k).publicKey.hex == f.identities[k]!.publicKey) }
        for m in f.messages {
            var inbox = LabInbox()
            var r: LabInbox.Result?
            for fr in m.frames.reversed() { r = try inbox.receive(frame: Data(hex: fr), from: card(m.from), identity: id(m.to), myNode: f.identities[m.to]!.node) }
            #expect(r == .message(text: m.text, counter: m.counter, chunks: m.frames.count))
        }
        for c in f.cards { #expect(PeerCard.find(in: "text before \(c.encoded) after")?.encoded == c.encoded) }
        var w = ReplayWindow()
        for s in f.replay {
            #expect(w.isFresh(s.counter) == s.accept, "replay step \(s.counter)")
            if s.accept { w.mark(s.counter) }
        }
        for t in f.tampered {
            var inbox = LabInbox()
            var r: LabInbox.Result?
            for fr in t.frames { r = try? inbox.receive(frame: Data(hex: fr), from: card("a"), identity: id("b"), myNode: f.identities["b"]!.node) }
            if case .message = r { Issue.record("tampered accepted: \(t.description)") }
        }
    }
}
