// PSST (L1): state of the „LoRa“ section of psst lab — one radio over Bluetooth, the Meshtastic client, peers.
import Combine
import Foundation
import PsstMesh
import PsstMeshBLE
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

@MainActor
public final class LabMeshModel: ObservableObject {
    public static let shared = LabMeshModel()

    @Published public private(set) var bluetoothProblem: String?
    @Published public private(set) var radios: [DiscoveredRadio] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var clientState: ClientState = .disconnected(nil)
    @Published public private(set) var bleBattery: Int?
    @Published public private(set) var bleRSSI: Int?
    @Published public private(set) var revision = 0          // bumps on every change of nodes/messages
    @Published public private(set) var lastEvent: String?
    @Published public private(set) var lastLinked: LabPeer?

    public let transport = CoreBluetoothTransport()
    public let client: MeshClient

    /// Set by the app after sign-in (the Matrix user of this phone), used in the card we hand out.
    public var matrixUserID: String?
    public var displayName: String = "psst lab"

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("psst-lab-lora", isDirectory: true)
        let keys = KeychainKeyStore(service: (Bundle.main.bundleIdentifier ?? "eu.macet.psst.lab") + ".lora")
        client = MeshClient(transport: transport, store: LabStateStore(directory: dir), identity: { try keys.loadOrCreateIdentity() })
        client.onChange = { [weak self] in self?.refresh() }
        client.onEvent = { [weak self] e in self?.lastEvent = e }
        client.onIncomingMessage = { [weak self] m in self?.notify(m) }
        // the time of the newest advertisement is the clock (real scanner: now; tests: a simulated clock)
        transport.onDiscovered = { [weak self] r in self?.radiosChanged(r, now: r.map(\.lastSeen).max() ?? Date()) }
        transport.onBluetoothState = { [weak self] p in self?.bluetoothProblem = p }
        transport.onBattery = { [weak self] b in self?.bleBattery = b }
        transport.onRSSI = { [weak self] r in self?.bleRSSI = r }
        if let s = client.labState.lastDeviceID, let id = UUID(uuidString: s) { transport.targetID = id }
    }

    private func refresh() {
        clientState = client.state
        revision &+= 1
    }

    // MARK: Device

    public var hasRememberedDevice: Bool { transport.targetID != nil }
    public var rememberedDeviceName: String? { client.labState.lastDeviceName }

    public func startScan() { scanning = true; transport.startScan() }
    public func stopScan() { scanning = false; transport.stopScan() }

    // PSST (L1c): CoreBluetooth reports every advertisement (AllowDuplicates) — dozens per second per radio. Publishing
    // each one re-rendered the whole LoRa hierarchy continuously. Scan results are coalesced: at most one update per
    // `radiosInterval`, the latest state always delivered (timer).
    static let radiosInterval: TimeInterval = 0.5
    private var pendingRadios: [DiscoveredRadio]?
    private var lastRadiosPublish = Date.distantPast
    private var radiosTimer: Timer?

    private func radiosChanged(_ r: [DiscoveredRadio], now: Date) {
        pendingRadios = r
        flushRadios(now: now)
        if pendingRadios != nil, radiosTimer == nil {
            radiosTimer = Timer.scheduledTimer(withTimeInterval: Self.radiosInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.radiosTimer = nil
                    self?.flushRadios()
                }
            }
        }
    }

    /// Publishes pending scan results if the last update is at least `radiosInterval` old.
    public func flushRadios(now: Date = Date()) {
        guard let r = pendingRadios, now.timeIntervalSince(lastRadiosPublish) >= Self.radiosInterval else { return }
        pendingRadios = nil
        lastRadiosPublish = now
        if r != radios { radios = r }
    }

    public func connect(_ radio: DiscoveredRadio) {
        stopScan()
        client.disconnect()
        transport.targetID = radio.id
        client.labState.lastDeviceID = radio.id.uuidString
        client.labState.lastDeviceName = radio.name
        client.connect()
    }

    /// Reconnects to the remembered radio (called when the LoRa screen opens).
    public func reconnectIfNeeded() {
        guard transport.targetID != nil else { return }
        if case .disconnected = client.state { client.connect() }
    }

    public func disconnect() { client.disconnect() }

    public func forgetDevice() {
        client.disconnect()
        transport.targetID = nil
        client.labState.lastDeviceID = nil
        client.labState.lastDeviceName = nil
        refresh()
    }

    public var battery: Int? { bleBattery ?? client.myNode?.batteryLevel }

    // MARK: Messages

    public func send(_ text: String, to c: Conversation, encrypted: Bool) throws {
        if encrypted, case .direct(let n) = c {
            try client.sendEncrypted(text, to: n)
        } else {
            try client.sendText(text, to: c)
        }
    }

    public func isLinked(_ node: UInt32) -> Bool { client.labState.peers[node] != nil }
    public func peer(_ node: UInt32) -> LabPeer? { client.labState.peers[node] }

    public func title(for c: Conversation) -> String {
        switch c {
        case .channel(let i):
            let ch = client.channels[i]
            let name = (ch?.name.isEmpty ?? true) ? (i == 0 ? "Verejný kanál" : "Kanál \(i)") : ch!.name
            return name
        case .direct(let n):
            if let p = peer(n) { return p.card.name.isEmpty ? (p.card.matrixUserID ?? MeshNode.userID(n)) : p.card.name }
            return client.node(n)?.displayName ?? MeshNode.userID(n)
        }
    }

    /// Conversations that have messages, newest first.
    public var conversations: [Conversation] {
        var last: [Conversation: Date] = [:]
        for m in client.labState.messages { last[m.conversation] = max(last[m.conversation] ?? .distantPast, m.date) }
        return last.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: Peers / cards

    public func myCard() -> PeerCard? { client.myCard(matrixUserID: matrixUserID, name: displayName) }

    /// Text of the psst (Matrix) message „Prepojiť s LoRa“ sends to a contact. nil = no radio paired yet.
    public func linkMessageBody() -> String? {
        guard let card = myCard() else { return nil }
        return """
        🔗 psst lab: prepojenie s LoRa
        Môj LoRa uzol \(MeshNode.userID(card.nodeNum)), kľúč \(LabIdentity.fingerprint(card.publicKey)).
        \(card.encoded)
        (Túto správu spracuje appka psst lab — v appke psst ju môžete ignorovať.)
        """
    }

    public func markCardSent(to userID: String) { client.labState.cardsSentTo[userID] = Date() }
    public func cardSent(to userID: String) -> Date? { client.labState.cardsSentTo[userID] }
    public func peer(matrixUserID: String) -> LabPeer? { client.labState.peers.values.first { $0.card.matrixUserID == matrixUserID } }

    /// Called by the app for every text message in a psst chat. A card is accepted only from its own Matrix user
    /// (the sender of the end-to-end encrypted message must be the user named in the card).
    /// Cards are applied in time order: a card older than the binding we have (e.g. met again while scrolling back in
    /// the history) never replaces a newer one.
    @discardableResult
    public func receivedMatrixMessage(body: String, sender: String, isOwn: Bool, timestamp: Date) -> Bool {
        guard !isOwn, body.contains(PeerCard.prefix), let card = PeerCard.find(in: body), card.matrixUserID == sender else { return false }
        if let existing = client.labState.peers[card.nodeNum], existing.card == card { return false }
        if let current = peer(matrixUserID: sender), current.linkedAt >= timestamp { return false }
        client.link(card: card, source: "matrix", linkedAt: timestamp)
        lastLinked = client.labState.peers[card.nodeNum]
        return true
    }

    /// Scanned / pasted card.
    public func linkScanned(_ text: String) -> PeerCard? {
        guard let card = PeerCard.find(in: text) else { return nil }
        client.link(card: card, source: "qr")
        lastLinked = client.labState.peers[card.nodeNum]
        return card
    }

    public func unlink(_ node: UInt32) { client.unlink(node: node) }

    // MARK: Local notification for LoRa messages while the app is in the background

    private func notify(_ m: LoRaMessage) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "LoRa: \(title(for: m.conversation))"
        content.body = m.text
        content.threadIdentifier = "psst-lab-lora"
        let req = UNNotificationRequest(identifier: m.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        #endif
    }
}
