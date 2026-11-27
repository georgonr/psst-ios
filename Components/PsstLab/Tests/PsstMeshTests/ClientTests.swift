// PSST (L1): MeshClient (Client API state machine, delivery states, E2E send/receive) with fake transports,
// a simulated two-phone mesh, and the BLE read/write cycle (BLESession) with a fake CoreBluetooth link.
import Foundation
import MeshtasticProtobufs
@testable import PsstMesh
@testable import PsstMeshBLE
import SwiftProtobuf
import Testing

@MainActor
final class FakeTransport: MeshTransport {
    var onFromRadio: ((Data) -> Void)?
    var onStateChange: ((TransportState) -> Void)?
    var sent: [ToRadio] = []
    var onSend: ((ToRadio) -> Void)?
    func start() { onStateChange?(.connected) }
    func send(_ d: Data) {
        let t = try! ToRadio(serializedBytes: d)
        sent.append(t)
        onSend?(t)
    }
    func stop() { onStateChange?(.disconnected(nil)) }
    func inject(_ fr: FromRadio) { onFromRadio?(try! fr.serializedData()) }
    var packets: [MeshPacket] { sent.compactMap { if case .packet(let p) = $0.payloadVariant { p } else { nil } } }
}

@MainActor
func readyClient(node: UInt32, others: [UInt32] = [], store: LabStateStore? = nil, identity: LabIdentity = LabIdentity())
    -> (MeshClient, FakeTransport) {
    let t = FakeTransport()
    let c = MeshClient(transport: t, store: store, identity: { identity })
    c.frameGap = 0
    c.connect()
    let nonce = t.sent.last!.wantConfigID
    var fr = FromRadio(); var mi = MyNodeInfo(); mi.myNodeNum = node; fr.myInfo = mi; t.inject(fr)
    for n in [node] + others {
        var ni = NodeInfo(); ni.num = n; ni.user.longName = "Node \(n)"; ni.user.shortName = "N"; ni.snr = 6.5
        if n != node { ni.user.publicKey = Data(repeating: 7, count: 32) }
        fr = FromRadio(); fr.nodeInfo = ni; t.inject(fr)
    }
    var ch = MeshtasticProtobufs.Channel(); ch.index = 0; ch.role = .primary; ch.settings.psk = Data([1])
    fr = FromRadio(); fr.channel = ch; t.inject(fr)
    var lora = Config.LoRaConfig(); lora.region = .eu868
    var cfg = Config(); cfg.lora = lora
    fr = FromRadio(); fr.config = cfg; t.inject(fr)
    fr = FromRadio(); fr.configCompleteID = nonce; t.inject(fr)
    return (c, t)
}

func routing(_ requestID: UInt32, from: UInt32, to: UInt32, error: Routing.Error = .none) -> FromRadio {
    var r = Routing(); r.errorReason = error
    var d = DataMessage(); d.portnum = .routingApp; d.payload = try! r.serializedData(); d.requestID = requestID
    var p = MeshPacket(); p.from = from; p.to = to; p.decoded = d; p.id = UInt32.random(in: 1...999_999)
    var fr = FromRadio(); fr.packet = p
    return fr
}

func waitUntil(_ seconds: Double = 3, _ cond: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await cond()
}

@Suite @MainActor struct ClientTests {
    let me: UInt32 = 0xBD46_0DF0, other: UInt32 = 0xEA25_1718

    @Test func connectSequence() {
        let (c, t) = readyClient(node: me, others: [other])
        #expect(t.sent.first?.wantConfigID != 0)
        #expect(c.state == .ready)
        #expect(c.myNodeNum == me)
        #expect(c.labState.nodes.count == 2)
        #expect(c.channels[0]?.security == .meshtasticDefaultKey)
        #expect(c.region == .eu868)
    }

    @Test func wrongConfigNonceDoesNotFinish() {
        let t = FakeTransport()
        let c = MeshClient(transport: t, store: nil, identity: { LabIdentity() })
        c.connect()
        var fr = FromRadio(); fr.configCompleteID = t.sent.last!.wantConfigID &+ 1; t.inject(fr)
        #expect(c.state == .configuring)
    }

    @Test func directTextDeliveryStates() throws {
        let (c, t) = readyClient(node: me, others: [other])
        let m = try c.sendText("ahoj", to: .direct(other))
        let p = try #require(t.packets.last)
        #expect(p.to == other && p.wantAck && p.decoded.portnum == .textMessageApp && p.decoded.payload == Data("ahoj".utf8))
        #expect(m.security == .meshtasticPKI)
        t.inject(routing(p.id, from: me, to: me)) // implicit ACK (relayed)
        #expect(c.labState.messages.last?.state == .sent)
        t.inject(routing(p.id, from: other, to: me))
        #expect(c.labState.messages.last?.state == .delivered)
    }

    @Test func broadcastAndFailure() throws {
        let (c, t) = readyClient(node: me, others: [other])
        _ = try c.sendText("všetkým", to: .channel(0))
        let p = try #require(t.packets.last)
        #expect(p.to == 0xFFFF_FFFF && p.channel == 0)
        #expect(c.labState.messages.last?.security == .meshtasticDefaultKey)
        t.inject(routing(p.id, from: me, to: me))
        #expect(c.labState.messages.last?.state == .sent)
        _ = try c.sendText("x", to: .direct(other))
        t.inject(routing(t.packets.last!.id, from: me, to: me, error: .maxRetransmit))
        guard case .failed(let why) = c.labState.messages.last?.state else { Issue.record("not failed"); return }
        #expect(why.contains("opakovaniach"))
    }

    @Test func limits() {
        let (c, _) = readyClient(node: me, others: [other])
        #expect(throws: MeshClientError.textTooLong(maxBytes: 200)) { try c.sendText(String(repeating: "č", count: 101), to: .channel(0)) }
        #expect(throws: MeshClientError.empty) { try c.sendText("", to: .channel(0)) }
        #expect(throws: MeshClientError.unknownPeer) { try c.sendEncrypted("x", to: other) }
        let off = MeshClient(transport: FakeTransport(), store: nil, identity: { LabIdentity() })
        #expect(throws: MeshClientError.notReady) { try off.sendText("x", to: .channel(0)) }
    }

    @Test func incomingTextAndNodeUpdate() {
        let (c, t) = readyClient(node: me, others: [other])
        var d = DataMessage(); d.portnum = .textMessageApp; d.payload = Data("čau".utf8)
        var p = MeshPacket(); p.from = other; p.to = me; p.id = 42; p.decoded = d; p.rxSnr = 9.5; p.rxRssi = -41; p.pkiEncrypted = true
        p.hopStart = 3; p.hopLimit = 2
        var fr = FromRadio(); fr.packet = p
        t.inject(fr)
        t.inject(fr) // duplicate delivery is ignored
        let msgs = c.messages(in: .direct(other))
        #expect(msgs.count == 1)
        #expect(msgs[0].text == "čau" && msgs[0].security == .meshtasticPKI && !msgs[0].outgoing)
        #expect(c.node(other)?.rssi == -41 && c.node(other)?.hopsAway == 1 && c.node(other)?.lastHeard != nil)
    }

    @Test func persistenceAcrossRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psstlab-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LabStateStore(directory: dir)
        let (c, _) = readyClient(node: me, others: [other], store: store)
        _ = try c.sendText("ostane", to: .channel(0))
        let c2 = MeshClient(transport: FakeTransport(), store: LabStateStore(directory: dir), identity: { LabIdentity() })
        #expect(c2.labState.messages.map(\.text) == ["ostane"])
        #expect(c2.myNodeNum == me)
    }

    @Test func unknownSenderFrameDropped() {
        let (c, t) = readyClient(node: me, others: [other])
        var d = DataMessage(); d.portnum = .privateApp; d.payload = Data([0xB1, 0, 0, 0, 1, 0, 1, 2, 3])
        var p = MeshPacket(); p.from = other; p.to = me; p.id = 5; p.decoded = d
        var fr = FromRadio(); fr.packet = p
        t.inject(fr)
        #expect(c.labState.messages.isEmpty)
    }

    @Test func endToEndOverSimulatedMesh() async throws {
        // phone A (radio me) and phone B (radio other); the "air" copies packets between the fake radios and ACKs them
        let idA = LabIdentity(), idB = LabIdentity()
        let (a, ta) = readyClient(node: me, others: [other], identity: idA)
        let (b, tb) = readyClient(node: other, others: [me], identity: idB)
        let cardA = try #require(a.myCard(matrixUserID: "@alica:psst.pro", name: "Alica"))
        let cardB = try #require(b.myCard(matrixUserID: "@boris:psst.pro", name: "Boris"))
        a.link(card: cardB, source: "matrix")
        b.link(card: cardA, source: "qr")
        var air: [(from: UInt32, MeshPacket)] = []
        func wire(_ src: FakeTransport, _ srcNode: UInt32, _ dst: FakeTransport, _ dstNode: UInt32) {
            src.onSend = { tr in
                guard case .packet(var p) = tr.payloadVariant, p.to == dstNode else { return }
                p.from = srcNode
                air.append((srcNode, p))
                DispatchQueue.main.async {
                    var fr = FromRadio(); fr.packet = p; dst.inject(fr)
                    src.inject(routing(p.id, from: dstNode, to: srcNode)) // ACK from the destination
                }
            }
        }
        wire(ta, me, tb, other)
        wire(tb, other, ta, me)

        let long = String(repeating: "Dlhá správa cez LoRa, šifrovaná psst lab. ", count: 12) // ~500 B → 3 frames
        let sent = try a.sendEncrypted(long, to: other)
        #expect(sent.chunks == 3)
        #expect(a.framesWaiting == 3) // stop-and-wait: one in flight, two queued
        #expect(ta.packets.count == 1)
        #expect(await waitUntil { a.labState.messages.last?.state == .delivered })
        #expect(ta.packets.count == 3)
        #expect(ta.packets.allSatisfy { $0.decoded.portnum == .privateApp && $0.wantAck && $0.decoded.payload.count <= 200 })
        // nobody else can read the air: payload bytes do not contain the text
        #expect(!air.contains { String(decoding: $0.1.decoded.payload, as: UTF8.self).contains("Dlhá") })
        let got = b.messages(in: .direct(me))
        #expect(got.count == 1 && got[0].text == long && got[0].security == .psstE2E && got[0].chunks == 3)

        // reply B → A
        _ = try b.sendEncrypted("Prijaté ✅", to: me)
        #expect(await waitUntil { a.messages(in: .direct(other)).contains { !$0.outgoing && $0.text == "Prijaté ✅" } })

        // replay: re-inject the first frame A sent → rejected, no new message at B
        let before = b.labState.messages.count
        var fr = FromRadio(); var p = air[0].1; p.id = 999; fr.packet = p
        tb.inject(fr)
        #expect(b.labState.messages.count == before)
        #expect(b.lastLog.contains { $0.contains("zopakovaná") })

        // counter persisted per peer
        #expect(a.labState.peers[other]?.sendCounter == 1)
        #expect(b.labState.peers[me]?.sendCounter == 1)
    }

    @Test func relinkWithNewKeyResetsCounters() throws {
        let (c, _) = readyClient(node: me, others: [other])
        let k1 = LabIdentity(), k2 = LabIdentity()
        c.link(card: PeerCard(nodeNum: other, publicKey: k1.publicKey, matrixUserID: "@b:psst.pro", name: "B"), source: "matrix")
        _ = try c.sendEncrypted("1", to: other)
        #expect(c.labState.peers[other]?.sendCounter == 1)
        c.link(card: PeerCard(nodeNum: other, publicKey: k2.publicKey, matrixUserID: "@b:psst.pro", name: "B"), source: "matrix")
        #expect(c.labState.peers[other]?.sendCounter == 0)
        // the same Matrix user on another node replaces the old binding
        c.link(card: PeerCard(nodeNum: 77, publicKey: k2.publicKey, matrixUserID: "@b:psst.pro", name: "B"), source: "matrix")
        #expect(c.labState.peers[other] == nil && c.labState.peers[77] != nil)
    }

    @Test func regionOnlySetWhenUnset() {
        let (c, t) = readyClient(node: me)
        #expect(c.setRegionEU868IfUnset() == false) // region is EU_868 → nothing sent
        #expect(!t.packets.contains { $0.decoded.portnum == .adminApp })
    }
}

// MARK: - BLE

@MainActor
final class FakeLink: BLELink {
    var reads = 0, subscribed = false
    var writes: [Data] = []
    func readFromRadio() { reads += 1 }
    func writeToRadio(_ data: Data) { writes.append(data) }
    func subscribeFromNum() { subscribed = true }
}

@Suite @MainActor struct BLESessionTests {
    @Test func drainsUntilEmpty() {
        let s = BLESession(); let l = FakeLink(); s.link = l
        var got: [Data] = []
        s.onFromRadio = { got.append($0) }
        s.drain()
        #expect(l.reads == 0) // not ready yet: nothing happens before the characteristics are found
        s.linkReady()
        #expect(l.subscribed && l.reads == 1)
        s.didRead(Data([1]), error: nil)
        s.didRead(Data([2]), error: nil)
        #expect(l.reads == 3)
        s.didRead(Data(), error: nil) // empty → stop
        #expect(l.reads == 3 && got == [Data([1]), Data([2])])
        s.didNotifyFromNum()
        #expect(l.reads == 4)
    }

    @Test func notifyDuringReadReadsAgain() {
        let s = BLESession(); let l = FakeLink(); s.link = l
        s.linkReady()
        s.didNotifyFromNum() // read in flight → only remembered
        #expect(l.reads == 1)
        s.didRead(Data(), error: nil)
        #expect(l.reads == 2)
    }

    @Test func writesAreSerializedAndFollowedByRead() {
        let s = BLESession(); let l = FakeLink(); s.link = l
        s.send(Data([1])) // before the link is ready: queued
        #expect(l.writes.isEmpty)
        s.linkReady()
        #expect(l.writes == [Data([1])] && l.reads == 1)
        s.send(Data([2]))
        #expect(l.writes == [Data([1])]) // one write-with-response at a time
        s.didWrite(error: nil)
        #expect(l.writes == [Data([1]), Data([2])])
        s.didRead(Data(), error: nil) // the read in flight finishes empty → read again (write happened meanwhile)
        #expect(l.reads == 2)
        s.didWrite(error: nil)
        s.reset()
        s.send(Data([3]))
        #expect(l.writes.count == 2) // after a disconnect nothing is written until the link is ready again
    }

    @Test func uuidsMatchOfficialAPI() {
        #expect(MeshtasticBLE.service == "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
        #expect(MeshtasticBLE.toRadio == "F75C76D2-129E-4DAD-A1DD-7866124401E7")
        #expect(MeshtasticBLE.fromRadio == "2C55E69E-4993-11ED-B878-0242AC120002")
        #expect(MeshtasticBLE.fromNum == "ED9DA18C-A800-4F66-A670-AA7547E34453")
    }
}
