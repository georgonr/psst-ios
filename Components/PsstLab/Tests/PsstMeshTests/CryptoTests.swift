// PSST (L1): psst lab LoRa E2E crypto, chunking, reassembly, replay protection, peer cards, stream framing.
import CryptoKit
import Foundation
@testable import PsstMesh
import Testing

struct Pair {
    let a = LabIdentity(), b = LabIdentity()
    let nodeA: UInt32 = 0xBD46_0DF0, nodeB: UInt32 = 0xEA25_1718
    var cardA: PeerCard { PeerCard(nodeNum: nodeA, publicKey: a.publicKey, matrixUserID: "@alica:psst.pro", name: "Alica") }
    var cardB: PeerCard { PeerCard(nodeNum: nodeB, publicKey: b.publicKey, matrixUserID: "@boris:psst.pro", name: "Boris") }
    func seal(_ t: String, _ c: UInt32 = 1) throws -> [Data] { try LabCrypto.seal(text: t, counter: c, identity: a, myNode: nodeA, peer: cardB) }
    func receiveAll(_ frames: [Data], inbox: inout LabInbox) throws -> LabInbox.Result? {
        var r: LabInbox.Result?
        for f in frames { r = try inbox.receive(frame: f, from: cardA, identity: b, myNode: nodeB) }
        return r
    }
}

@Suite struct CryptoTests {
    @Test func singleFrameRoundTrip() throws {
        let p = Pair()
        let frames = try p.seal("Ahoj 👋")
        #expect(frames.count == 1)
        #expect(frames[0].count == 6 + 1 + Data("Ahoj 👋".utf8).count + 16)
        var inbox = LabInbox()
        #expect(try p.receiveAll(frames, inbox: &inbox) == .message(text: "Ahoj 👋", counter: 1, chunks: 1))
    }

    @Test func chunkedRoundTripAnyOrderAndSizeLimit() throws {
        let p = Pair()
        let text = String(repeating: "Príliš žltučký kôň úpel ďábelské ódy. ", count: 30) // ~1.2 kB with diacritics
        let frames = try p.seal(text, 7)
        #expect(frames.count == Int((Double(Data(text.utf8).count + 17) / 194).rounded(.up)))
        #expect(frames.allSatisfy { $0.count <= LabFormat.maxFrameBytes })
        var inbox = LabInbox()
        var last: LabInbox.Result?
        for (i, f) in frames.shuffled().enumerated() {
            last = try inbox.receive(frame: f, from: p.cardA, identity: p.b, myNode: p.nodeB)
            if i < frames.count - 1 { #expect(last == .incomplete(received: i + 1, of: frames.count)) }
        }
        #expect(last == .message(text: text, counter: 7, chunks: frames.count))
    }

    @Test func duplicateChunkIsIgnored() throws {
        let p = Pair()
        let frames = try p.seal(String(repeating: "x", count: 500))
        var inbox = LabInbox()
        _ = try inbox.receive(frame: frames[0], from: p.cardA, identity: p.b, myNode: p.nodeB)
        #expect(try inbox.receive(frame: frames[0], from: p.cardA, identity: p.b, myNode: p.nodeB) == .duplicateFrame)
    }

    @Test func tooLongIsRejected() throws {
        let p = Pair()
        let max = LabFormat.maxTextBytes()
        #expect(max == 8 * 194 - 17)
        _ = try p.seal(String(repeating: "a", count: max))
        #expect(throws: LabCryptoError.messageTooLong(maxBytes: max)) { try p.seal(String(repeating: "a", count: max + 1)) }
    }

    @Test func tamperedFrameFailsAuthentication() throws {
        let p = Pair()
        for position in [7, 6, 1, 5] { // ciphertext, first body byte, counter (AAD + nonce), chunk byte (AAD)
            var frames = try p.seal("tajné")
            frames[0][position] ^= 0x01
            var inbox = LabInbox()
            // either authentication fails or (changed chunk count) the message never completes — never a message
            let r = try? p.receiveAll(frames, inbox: &inbox)
            if case .message = r { Issue.record("tampered frame at \(position) was accepted") }
        }
    }

    @Test func otherKeyCannotRead() throws {
        let p = Pair()
        let frames = try p.seal("len pre Borisa")
        let eve = LabIdentity()
        var inbox = LabInbox()
        #expect(throws: LabCryptoError.authenticationFailed) {
            try inbox.receive(frame: frames[0], from: p.cardA, identity: eve, myNode: p.nodeB)
        }
        // somebody posing as Alica (her node number, but Eve's key)
        let fake = PeerCard(nodeNum: p.nodeA, publicKey: eve.publicKey, matrixUserID: nil, name: "Alica?")
        let forged = try LabCrypto.seal(text: "som Alica", counter: 1, identity: eve, myNode: p.nodeA, peer: p.cardB)
        _ = fake
        var inbox2 = LabInbox()
        #expect(throws: LabCryptoError.authenticationFailed) { try p.receiveAll(forged, inbox: &inbox2) }
    }

    @Test func reflectedFrameIsRejected() throws {
        // A→B frame sent back to A as if it came from B: different direction key → fails
        let p = Pair()
        let frames = try p.seal("ping")
        var inbox = LabInbox()
        #expect(throws: LabCryptoError.authenticationFailed) {
            try inbox.receive(frame: frames[0], from: p.cardB, identity: p.a, myNode: p.nodeA)
        }
    }

    @Test func replayIsRejected() throws {
        let p = Pair()
        let m1 = try p.seal("prvá", 1)
        let m2 = try p.seal("druhá", 2)
        var inbox = LabInbox()
        _ = try p.receiveAll(m1, inbox: &inbox)
        _ = try p.receiveAll(m2, inbox: &inbox)
        #expect(throws: LabCryptoError.replayed(counter: 1)) { try p.receiveAll(m1, inbox: &inbox) }
        #expect(throws: LabCryptoError.replayed(counter: 2)) { try p.receiveAll(m2, inbox: &inbox) }
        // windows survive a restart (persisted in LabState)
        var restarted = LabInbox(windows: inbox.windows)
        #expect(throws: LabCryptoError.replayed(counter: 2)) { try p.receiveAll(m2, inbox: &restarted) }
    }

    @Test func outOfOrderWithinWindowAccepted() throws {
        let p = Pair()
        var inbox = LabInbox()
        _ = try p.receiveAll(p.seal("10", 10), inbox: &inbox)
        #expect(try p.receiveAll(p.seal("9", 9), inbox: &inbox) == .message(text: "9", counter: 9, chunks: 1))
        _ = try p.receiveAll(p.seal("100", 100), inbox: &inbox)
        #expect(throws: LabCryptoError.replayed(counter: 30)) { try p.receiveAll(p.seal("30", 30), inbox: &inbox) } // older than 64
        #expect(try p.receiveAll(p.seal("40", 40), inbox: &inbox) == .message(text: "40", counter: 40, chunks: 1))
    }

    @Test func failedMessageDoesNotBurnCounter() throws {
        let p = Pair()
        var frames = try p.seal("x", 5)
        frames[0][8] ^= 0xFF
        var inbox = LabInbox()
        #expect(throws: (any Error).self) { try p.receiveAll(frames, inbox: &inbox) }
        #expect(try p.receiveAll(p.seal("x", 5), inbox: &inbox) == .message(text: "x", counter: 5, chunks: 1))
    }

    @Test func replayWindowBasics() {
        var w = ReplayWindow()
        #expect(!w.isFresh(0))
        w.mark(1); w.mark(3)
        #expect(!w.isFresh(1) && w.isFresh(2) && !w.isFresh(3) && w.isFresh(4))
        w.mark(200)
        #expect(!w.isFresh(136) && w.isFresh(137) && !w.isFresh(200))
    }

    @Test func peerCardRoundTripInMessageText() throws {
        let p = Pair()
        let body = "🔗 psst lab: prepojenie s LoRa\nUzol !bd460df0 · kľúč \(LabIdentity.fingerprint(p.a.publicKey))\n\(p.cardA.encoded)\n(Otvorte v appke psst lab.)"
        #expect(PeerCard.find(in: body) == p.cardA)
        let noMx = PeerCard(nodeNum: 1, publicKey: p.b.publicKey, matrixUserID: nil, name: "")
        #expect(PeerCard.find(in: noMx.encoded) == noMx)
        #expect(PeerCard.find(in: "psstlab1:AAAA") == nil)
        #expect(PeerCard.find(in: "bez karty") == nil)
        #expect(p.cardA.encoded.count < 140) // fits comfortably into a QR code
    }

    @Test func fingerprintFormat() {
        let f = LabIdentity.fingerprint(Data(repeating: 1, count: 32))
        #expect(f.count == 19 && f.split(separator: " ").count == 4)
    }
}

@Suite struct FramingTests {
    @Test func roundTripWithDebugTextAndSplits() {
        let a = Data((0..<300).map { UInt8($0 & 0xFF) })
        let b = Data([0x94, 0xC3, 0x01]) // contains START bytes itself
        var stream = Data("INFO boot\n".utf8)
        stream.append(StreamFraming.frame(a))
        stream.append(Data("DEBUG x\n".utf8))
        stream.append(StreamFraming.frame(b))
        var d = StreamDeframer()
        var got: [Data] = []
        var i = 0
        while i < stream.count { // feed in odd-sized pieces
            let n = min(7, stream.count - i)
            got += d.feed(stream.subdata(in: i..<(i + n)))
            i += n
        }
        #expect(got == [a, b])
        #expect(d.takeDebugLines() == ["INFO boot", "DEBUG x"])
    }

    @Test func corruptLengthResyncs() {
        var s = Data([0x94, 0xC3, 0x7F, 0xFF]) // 32767 > 512 → corrupt
        s.append(StreamFraming.frame(Data([1, 2, 3])))
        var d = StreamDeframer()
        #expect(d.feed(s) == [Data([1, 2, 3])])
    }

    @Test func headerLayout() {
        #expect(StreamFraming.frame(Data([9])) == Data([0x94, 0xC3, 0x00, 0x01, 9]))
        #expect(StreamFraming.wakeSequence == Data(repeating: 0xC3, count: 32))
    }
}
