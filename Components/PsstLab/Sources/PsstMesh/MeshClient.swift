// PSST (L1): Meshtastic Client API over any transport (BLE on the iPhone, serial on the Mac).
// Protocol (https://meshtastic.org/docs/development/device/client-api/): the client writes ToRadio protobufs; the radio
// answers with FromRadio protobufs. After connecting the client sends ToRadio.want_config_id = <nonce>; the radio sends
// my_info, metadata, node_info…, channels, config, module config and finally config_complete_id = <nonce>.
import Foundation
import MeshtasticProtobufs
import SwiftProtobuf

public enum TransportState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected(String?)
}

/// Bytes in, bytes out. One `send` = one encoded ToRadio; one `onFromRadio` = one encoded FromRadio.
@MainActor
public protocol MeshTransport: AnyObject {
    var onFromRadio: ((Data) -> Void)? { get set }
    var onStateChange: ((TransportState) -> Void)? { get set }
    func start()
    func send(_ toRadio: Data)
    func stop()
}

public enum ClientState: Equatable, Sendable {
    case disconnected(String?)
    case connecting
    case configuring
    case ready
}

public enum MeshClientError: Error, Equatable, LocalizedError {
    case notReady
    case textTooLong(maxBytes: Int)
    case unknownPeer
    case empty

    public var errorDescription: String? {
        switch self {
        case .notReady: psstTr("lora_err_not_ready")
        case .textTooLong(let n): psstTr("lora_err_too_long", n)
        case .unknownPeer: psstTr("lora_err_unknown_peer")
        case .empty: psstTr("lora_err_empty")
        }
    }
}

/// Port numbers used here (portnums.proto): TEXT_MESSAGE_APP = 1, ROUTING_APP = 5, NODEINFO_APP = 4,
/// TELEMETRY_APP = 67, PRIVATE_APP = 256 (psst lab frames — other Meshtastic apps do not show them as text).
@MainActor
public final class MeshClient {
    public static let maxPlainTextBytes = 200
    public static let broadcast: UInt32 = 0xFFFF_FFFF
    public static let ackTimeout: TimeInterval = 120

    public let transport: MeshTransport
    public private(set) var state: ClientState = .disconnected(nil)
    public private(set) var myNodeNum: UInt32?
    public private(set) var firmwareVersion: String?
    public private(set) var region: Config.LoRaConfig.RegionCode?
    public private(set) var modemPreset: String?
    public private(set) var channels: [Int: ChannelInfo] = [:]
    public private(set) var lastLog: [String] = []

    public var labState: LabState { didSet { persist() } }
    private let store: LabStateStore?
    private var identityProvider: () throws -> LabIdentity
    private lazy var identity: LabIdentity? = try? identityProvider()
    private var inbox: LabInbox
    private var configNonce: UInt32 = 0
    private var heartbeat: Timer?
    private var timeoutTimer: Timer?

    /// Change notification for UIs and the CLI (state, nodes, messages).
    public var onChange: (() -> Void)?
    public var onEvent: ((String) -> Void)?
    public var onIncomingMessage: ((LoRaMessage) -> Void)?

    public init(transport: MeshTransport, store: LabStateStore?, identity: @escaping () throws -> LabIdentity) {
        self.transport = transport
        self.store = store
        identityProvider = identity
        let s = store?.load() ?? LabState()
        labState = s
        inbox = LabInbox(windows: s.replayWindows)
        myNodeNum = s.myNodeNum
        transport.onFromRadio = { [weak self] d in self?.handle(fromRadio: d) }
        transport.onStateChange = { [weak self] st in self?.transportChanged(st) }
    }

    public var myIdentity: LabIdentity? { identity }

    // MARK: Connection

    public func connect() {
        state = .connecting
        changed()
        transport.start()
    }

    public func disconnect() {
        heartbeat?.invalidate(); heartbeat = nil
        transport.stop()
        state = .disconnected(nil)
        changed()
    }

    private func transportChanged(_ st: TransportState) {
        switch st {
        case .connected:
            state = .configuring
            requestConfig()
            heartbeat?.invalidate()
            // the serial API drops idle clients after a while; official clients send a heartbeat every few minutes
            heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendHeartbeat() }
            }
            if timeoutTimer == nil {
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.expireUnacked() }
                }
            }
        case .connecting: state = .connecting
        case .idle: state = .disconnected(nil)
        case .disconnected(let why):
            heartbeat?.invalidate(); heartbeat = nil
            state = .disconnected(why)
            frameQueue.removeAll(); inFlight = nil
            failPending(reason: psstTr("lora_ev_link_lost"))
        }
        changed()
    }

    public func requestConfig() {
        configNonce = UInt32.random(in: 1...UInt32.max - 1)
        var tr = ToRadio()
        tr.wantConfigID = configNonce
        send(tr)
    }

    private func sendHeartbeat() {
        var tr = ToRadio()
        tr.heartbeat = Heartbeat()
        send(tr)
    }

    private func send(_ tr: ToRadio) {
        guard let d = try? tr.serializedData() else { return }
        transport.send(d)
    }

    // MARK: Incoming

    public func handle(fromRadio data: Data) {
        guard !data.isEmpty, let fr = try? FromRadio(serializedBytes: data) else { return }
        switch fr.payloadVariant {
        case .myInfo(let mi):
            myNodeNum = mi.myNodeNum
            labState.myNodeNum = mi.myNodeNum
        case .nodeInfo(let ni):
            upsert(nodeInfo: ni)
        case .metadata(let md):
            firmwareVersion = md.firmwareVersion
        case .channel(let ch):
            let psk = ch.settings.psk.count
            channels[Int(ch.index)] = ChannelInfo(index: Int(ch.index), name: ch.settings.name,
                                                  role: String(describing: ch.role).uppercased(), pskLength: psk)
            if ch.role == .disabled { channels[Int(ch.index)] = nil }
        case .config(let c):
            if case .lora(let lora) = c.payloadVariant {
                region = lora.region
                lastLoRaConfig = lora
                modemPreset = String(describing: lora.modemPreset)
            }
        case .configCompleteID(let id):
            if id == configNonce {
                state = .ready
                event(psstTr("lora_ev_config", labState.nodes.count, channels.count))
            }
        case .packet(let p):
            handle(packet: p)
        case .queueStatus(let q):
            if q.res != 0 { event(psstTr("lora_ev_queue", q.meshPacketID, q.res)) }
        case .clientNotification(let n):
            event(psstTr("lora_ev_radio", n.message))
        case .logRecord(let l):
            log(l.message)
        case .rebooted:
            event(psstTr("lora_ev_rebooted"))
            requestConfig()
        default:
            break
        }
        changed()
    }

    private func upsert(nodeInfo ni: NodeInfo) {
        var n = labState.nodes[ni.num] ?? MeshNode(num: ni.num)
        if ni.hasUser {
            n.userID = ni.user.id.isEmpty ? MeshNode.userID(ni.num) : ni.user.id
            n.longName = ni.user.longName
            n.shortName = ni.user.shortName
            n.hwModel = String(describing: ni.user.hwModel)
            n.publicKey = ni.user.publicKey.isEmpty ? n.publicKey : ni.user.publicKey
        }
        if ni.lastHeard > 0 { n.lastHeard = Date(timeIntervalSince1970: TimeInterval(ni.lastHeard)) }
        if ni.snr != 0 { n.snr = ni.snr }
        if ni.hasHopsAway { n.hopsAway = Int(ni.hopsAway) }
        if ni.hasDeviceMetrics {
            if ni.deviceMetrics.hasBatteryLevel { n.batteryLevel = Int(ni.deviceMetrics.batteryLevel) }
            if ni.deviceMetrics.hasVoltage { n.voltage = ni.deviceMetrics.voltage }
        }
        n.viaMqtt = ni.viaMqtt
        labState.nodes[ni.num] = n
    }

    private func touch(node num: UInt32, packet p: MeshPacket) {
        guard num != myNodeNum else { return }
        var n = labState.nodes[num] ?? MeshNode(num: num)
        n.lastHeard = p.rxTime > 0 ? Date(timeIntervalSince1970: TimeInterval(p.rxTime)) : Date()
        if p.rxSnr != 0 { n.snr = p.rxSnr }
        if p.rxRssi != 0 { n.rssi = p.rxRssi }
        if p.hopStart > 0, p.hopStart >= p.hopLimit { n.hopsAway = Int(p.hopStart - p.hopLimit) }
        n.viaMqtt = p.viaMqtt
        labState.nodes[num] = n
    }

    private func handle(packet p: MeshPacket) {
        touch(node: p.from, packet: p)
        guard case .decoded(let d) = p.payloadVariant else { return } // still encrypted: not for us / unknown channel
        switch d.portnum {
        case .textMessageApp:
            let toMe = p.to != Self.broadcast
            let security: MessageSecurity = toMe
                ? (p.pkiEncrypted ? .meshtasticPKI : channels[Int(p.channel)]?.security ?? .meshtasticChannel)
                : channels[Int(p.channel)]?.security ?? .meshtasticChannel
            var m = LoRaMessage(conversation: toMe ? .direct(p.from) : .channel(Int(p.channel)), outgoing: false,
                                fromNode: p.from, text: String(decoding: d.payload, as: UTF8.self),
                                date: p.rxTime > 0 ? Date(timeIntervalSince1970: TimeInterval(p.rxTime)) : Date(),
                                security: security, state: .delivered, packetIDs: [p.id])
            m.rxSnr = p.rxSnr; m.rxRssi = p.rxRssi
            m.hops = p.hopStart > 0 ? Int(p.hopStart) - Int(p.hopLimit) : nil
            appendIncoming(m)
        case .privateApp:
            handleLabFrame(d.payload, packet: p)
        case .routingApp:
            guard let r = try? Routing(serializedBytes: d.payload) else { return }
            handleRouting(r, requestID: d.requestID, from: p.from)
        case .nodeinfoApp:
            if let u = try? User(serializedBytes: d.payload) {
                var ni = NodeInfo()
                ni.num = p.from
                ni.user = u
                upsert(nodeInfo: ni)
            }
        case .telemetryApp:
            if let t = try? Telemetry(serializedBytes: d.payload), case .deviceMetrics(let dm) = t.variant {
                var n = labState.nodes[p.from] ?? MeshNode(num: p.from)
                if dm.hasBatteryLevel { n.batteryLevel = Int(dm.batteryLevel) }
                if dm.hasVoltage { n.voltage = dm.voltage }
                labState.nodes[p.from] = n
            }
        default:
            break
        }
    }

    private func appendIncoming(_ m: LoRaMessage) {
        // the radio may hand a packet to the client twice (e.g. after a reconnect): de-duplicate by packet ID + sender
        if labState.messages.contains(where: { !$0.outgoing && $0.fromNode == m.fromNode && $0.packetIDs == m.packetIDs }) { return }
        labState.messages.append(m)
        onIncomingMessage?(m)
    }

    private func handleLabFrame(_ payload: Data, packet p: MeshPacket) {
        guard LabFrame.isLabFrame(payload) else { return }
        guard let peer = labState.peers[p.from]?.card else {
            event(psstTr("lora_ev_unlinked_frame", MeshNode.userID(p.from)))
            return
        }
        guard let identity, let me = myNodeNum, p.to == me else { return }
        do {
            let r = try inbox.receive(frame: payload, from: peer, identity: identity, myNode: me)
            switch r {
            case .incomplete(let got, let of):
                event(psstTr("lora_ev_part", got, of, peer.name))
            case .duplicateFrame:
                break
            case .message(let text, _, let chunks):
                var m = LoRaMessage(conversation: .direct(p.from), outgoing: false, fromNode: p.from, text: text,
                                    security: .psstE2E, state: .delivered, packetIDs: [p.id], chunks: chunks)
                m.rxSnr = p.rxSnr; m.rxRssi = p.rxRssi
                labState.replayWindows = inbox.windows
                appendIncoming(m)
            }
        } catch LabCryptoError.replayed(let c) {
            event(psstTr("lora_ev_replayed", c, peer.name))
        } catch {
            event(psstTr("lora_ev_auth_failed", peer.name, error))
        }
    }

    private func handleRouting(_ r: Routing, requestID: UInt32, from: UInt32) {
        guard requestID != 0, let i = labState.messages.lastIndex(where: { $0.outgoing && $0.packetIDs.contains(requestID) }) else { return }
        var m = labState.messages[i]
        if case .errorReason(let e) = r.variant, e != .none {
            if m.state != .delivered { m.state = .failed(Self.describe(e)) }
        } else {
            let destination: UInt32? = { if case .direct(let n) = m.conversation { return n } else { return nil } }()
            if let destination, from == destination {
                if !m.ackedPacketIDs.contains(requestID) { m.ackedPacketIDs.append(requestID) }
                m.state = Set(m.ackedPacketIDs) == Set(m.packetIDs) ? .delivered : .sent
            } else {
                // implicit ACK (our radio heard a neighbour relay it) or the broadcast was transmitted
                if !m.relayedPacketIDs.contains(requestID) { m.relayedPacketIDs.append(requestID) }
                if m.state != .delivered { m.state = .sent }
            }
        }
        m.lastActivity = Date()
        labState.messages[i] = m
        if inFlight?.packetID == requestID {
            inFlight = nil
            if case .failed = m.state { frameQueue.removeAll { $0.messageID == m.id } }
            // let the channel clear (the ACK just came over the air) before the next frame
            DispatchQueue.main.asyncAfter(deadline: .now() + frameGap) { [weak self] in self?.pumpFrames() }
        }
    }

    // MARK: Frame pacing (stop-and-wait)
    // All frames of a chunked message handed to the radio at once compete with the ACKs for airtime; on the real
    // Heltec ↔ T-LoRa test only 1 of 3 frames was ACKed within 120 s. One frame in flight at a time: the next frame
    // goes out after the radio reports the ACK / error of the previous one (or after frameTimeout).
    struct PendingFrame { let messageID: UUID; let packetID: UInt32; let to: UInt32; let payload: Data }
    private var frameQueue: [PendingFrame] = []
    private var inFlight: (packetID: UInt32, since: Date)?
    public var frameGap: TimeInterval = 1.0
    public static let frameTimeout: TimeInterval = 75

    private func pumpFrames() {
        guard inFlight == nil, state == .ready, !frameQueue.isEmpty else { return }
        let f = frameQueue.removeFirst()
        inFlight = (f.packetID, Date())
        sendPacket(id: f.packetID, to: f.to, channel: 0, port: .privateApp, payload: f.payload)
    }

    public var framesWaiting: Int { frameQueue.count + (inFlight == nil ? 0 : 1) }

    static func describe(_ e: Routing.Error) -> String {
        switch e {
        case .maxRetransmit: psstTr("lora_rt_max_retransmit")
        case .noRoute: psstTr("lora_rt_no_route")
        case .gotNak: psstTr("lora_rt_nak")
        case .timeout: psstTr("lora_rt_timeout")
        case .noInterface: psstTr("lora_rt_no_interface")
        case .noChannel: psstTr("lora_rt_no_channel")
        case .tooLarge: psstTr("lora_rt_too_large")
        case .noResponse: psstTr("lora_rt_no_response")
        case .dutyCycleLimit: psstTr("lora_rt_duty")
        case .pkiFailed: psstTr("lora_rt_pki_failed")
        case .pkiUnknownPubkey: psstTr("lora_rt_pki_unknown")
        case .notAuthorized: psstTr("lora_rt_not_authorized")
        case .rateLimitExceeded: psstTr("lora_rt_rate")
        default: psstTr("lora_rt_other", e)
        }
    }

    private func expireUnacked() {
        let now = Date()
        var changedAny = false
        if let f = inFlight, now.timeIntervalSince(f.since) > Self.frameTimeout {
            inFlight = nil // the radio's own retries are over by now; the message timeout below decides
            pumpFrames()
        }
        let waiting = Set(frameQueue.map(\.messageID))
        for i in labState.messages.indices where labState.messages[i].outgoing {
            let m = labState.messages[i]
            if waiting.contains(m.id) { continue }
            if (m.state == .queued || m.state == .sent), now.timeIntervalSince(m.lastActivity ?? m.date) > Self.ackTimeout {
                if case .direct = m.conversation {
                    labState.messages[i].state = .failed(psstTr("lora_no_ack", Int(Self.ackTimeout)))
                    changedAny = true
                } else if m.state == .queued {
                    labState.messages[i].state = .failed(psstTr("lora_not_reported_sent"))
                    changedAny = true
                }
            }
        }
        if changedAny { changed() }
    }

    private func failPending(reason: String) {
        for i in labState.messages.indices where labState.messages[i].outgoing && labState.messages[i].state == .queued {
            labState.messages[i].state = .failed(reason)
        }
    }

    // MARK: Sending

    /// Plain Meshtastic text (TEXT_MESSAGE_APP): to the channel (broadcast) or directly to a node.
    @discardableResult
    public func sendText(_ text: String, to conversation: Conversation) throws -> LoRaMessage {
        guard state == .ready, let me = myNodeNum else { throw MeshClientError.notReady }
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty else { throw MeshClientError.empty }
        guard bytes.count <= Self.maxPlainTextBytes else { throw MeshClientError.textTooLong(maxBytes: Self.maxPlainTextBytes) }
        let (dest, channel): (UInt32, Int) = switch conversation {
        case .channel(let c): (Self.broadcast, c)
        case .direct(let n): (n, 0)
        }
        let id = newPacketID()
        sendPacket(id: id, to: dest, channel: channel, port: .textMessageApp, payload: bytes)
        let security: MessageSecurity = if case .direct(let n) = conversation, labState.nodes[n]?.publicKey != nil {
            .meshtasticPKI
        } else {
            channels[channel]?.security ?? .meshtasticChannel
        }
        let m = LoRaMessage(conversation: conversation, outgoing: true, fromNode: me, text: text, security: security,
                            state: .queued, packetIDs: [id])
        labState.messages.append(m)
        changed()
        return m
    }

    /// psst lab E2E message to a linked peer (PRIVATE_APP, one packet per frame, each with want_ack).
    @discardableResult
    public func sendEncrypted(_ text: String, to node: UInt32) throws -> LoRaMessage {
        guard state == .ready, let me = myNodeNum, let identity else { throw MeshClientError.notReady }
        guard var peer = labState.peers[node] else { throw MeshClientError.unknownPeer }
        guard !text.isEmpty else { throw MeshClientError.empty }
        guard Data(text.utf8).count <= LabFormat.maxTextBytes() else { throw MeshClientError.textTooLong(maxBytes: LabFormat.maxTextBytes()) }
        peer.sendCounter += 1
        labState.peers[node] = peer // persisted (didSet) before anything goes on air: a counter is never reused
        let frames = try LabCrypto.seal(text: text, counter: peer.sendCounter, identity: identity, myNode: me, peer: peer.card)
        let ids = frames.map { _ in newPacketID() }
        let m = LoRaMessage(conversation: .direct(node), outgoing: true, fromNode: me, text: text, security: .psstE2E,
                            state: .queued, packetIDs: ids, chunks: frames.count)
        labState.messages.append(m)
        for (id, f) in zip(ids, frames) { frameQueue.append(PendingFrame(messageID: m.id, packetID: id, to: node, payload: f)) }
        pumpFrames()
        changed()
        return m
    }

    private func sendPacket(id: UInt32, to: UInt32, channel: Int, port: PortNum, payload: Data) {
        var data = DataMessage()
        data.portnum = port
        data.payload = payload
        var p = MeshPacket()
        p.id = id
        p.to = to
        p.channel = UInt32(channel)
        p.wantAck = true
        p.decoded = data
        var tr = ToRadio()
        tr.packet = p
        send(tr)
    }

    private func newPacketID() -> UInt32 { UInt32.random(in: 1...0x7FFF_FFFF) }

    // MARK: Peers

    public func link(card: PeerCard, source: String, linkedAt: Date = Date()) {
        var peer = labState.peers[card.nodeNum] ?? LabPeer(card: card, source: source, linkedAt: linkedAt, sendCounter: 0)
        if peer.card.publicKey != card.publicKey {
            // a new key for the node: new key pair on the other side → old counters/windows no longer apply
            peer = LabPeer(card: card, source: source, linkedAt: linkedAt, sendCounter: 0)
            inbox.windows[card.nodeNum] = nil
            labState.replayWindows[card.nodeNum] = nil
        } else {
            peer.card = card
            peer.source = source
            peer.linkedAt = linkedAt
        }
        // a Matrix user moving to another node: drop the old binding
        if let mx = card.matrixUserID {
            for (n, p) in labState.peers where p.card.matrixUserID == mx && n != card.nodeNum { labState.peers[n] = nil }
        }
        labState.peers[card.nodeNum] = peer
        changed()
    }

    public func unlink(node: UInt32) {
        labState.peers[node] = nil
        changed()
    }

    public func myCard(matrixUserID: String?, name: String) -> PeerCard? {
        guard let me = myNodeNum, let identity else { return nil }
        return PeerCard(nodeNum: me, publicKey: identity.publicKey, matrixUserID: matrixUserID, name: name)
    }

    public func deleteMessages(in conversation: Conversation) {
        labState.messages.removeAll { $0.conversation == conversation }
        changed()
    }

    // MARK: Admin (only used when the region is not set — DECISIONS L1-08)

    /// Sets the LoRa region to EU_868 ONLY if the radio reports UNSET. Returns false when nothing was done.
    @discardableResult
    public func setRegionEU868IfUnset(currentLoRa: Config.LoRaConfig? = nil) -> Bool {
        guard state == .ready, let me = myNodeNum, region == .unset, var lora = currentLoRa ?? lastLoRaConfig else { return false }
        lora.region = .eu868
        var cfg = Config()
        cfg.lora = lora
        var admin = AdminMessage()
        admin.setConfig = cfg
        guard let payload = try? admin.serializedData() else { return false }
        var data = DataMessage()
        data.portnum = .adminApp
        data.payload = payload
        data.wantResponse = true
        var p = MeshPacket()
        p.id = newPacketID(); p.to = me; p.from = me; p.wantAck = true; p.decoded = data
        var tr = ToRadio()
        tr.packet = p
        send(tr)
        event(psstTr("lora_ev_region"))
        return true
    }

    private var lastLoRaConfig: Config.LoRaConfig?

    // MARK: Helpers

    public func node(_ num: UInt32) -> MeshNode? { labState.nodes[num] }

    public var myNode: MeshNode? { myNodeNum.flatMap { labState.nodes[$0] } }

    public func messages(in c: Conversation) -> [LoRaMessage] { labState.messages.filter { $0.conversation == c } }

    private func event(_ s: String) {
        log(s)
        onEvent?(s)
    }

    private func log(_ s: String) {
        lastLog.append(s)
        if lastLog.count > 200 { lastLog.removeFirst(lastLog.count - 200) }
    }

    private func changed() { onChange?() }

    private func persist() {
        store?.save(labState)
    }
}
