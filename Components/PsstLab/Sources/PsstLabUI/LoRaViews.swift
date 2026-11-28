// PSST (L1): „LoRa“ screens of psst lab — device, nodes, conversations (separate from the Matrix chats).
import CoreImage.CIFilterBuiltins
import PsstMesh
import PsstMeshBLE
import SwiftUI

// MARK: - Root

/// Screens inside LoRa. PSST (L1c): everything is pushed on ONE NavigationStack owned by the root — no sheets
/// attached to List rows/sections (SwiftUI tears such presentations down when the List re-renders its rows).
public enum LoRaRoute: Hashable {
    case scan, nodes, myCard, linkCard, peers, security
    case conversation(Conversation)
}

public struct LoRaRootView: View {
    @ObservedObject var model: LabMeshModel
    let onClose: () -> Void
    @State private var path: [LoRaRoute] = []

    public init(model: LabMeshModel = .shared, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                DeviceSection(model: model) { path.append(.scan) }
                Section(psstTr("lora_conversations")) {
                    ForEach(channelList, id: \.self) { c in
                        NavigationLink(value: LoRaRoute.conversation(c)) { ConversationRow(model: model, conversation: c) }
                    }
                    ForEach(model.conversations.filter { if case .direct = $0 { true } else { false } }, id: \.self) { c in
                        NavigationLink(value: LoRaRoute.conversation(c)) { ConversationRow(model: model, conversation: c) }
                    }
                    NavigationLink(value: LoRaRoute.nodes) {
                        Label(psstTr("lora_new_direct"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Section {
                    NavigationLink(value: LoRaRoute.myCard) { Label(psstTr("lora_my_key_qr"), systemImage: "qrcode") }
                    NavigationLink(value: LoRaRoute.linkCard) { Label(psstTr("lora_link_qr"), systemImage: "qrcode.viewfinder") }
                    NavigationLink(value: LoRaRoute.peers) {
                        Label(psstTr("lora_linked_count", model.client.labState.peers.count), systemImage: "person.2.badge.key")
                    }
                } header: { Text(psstTr("lora_psst_encryption")) } footer: {
                    Text(psstTr("lora_psst_encryption_footer"))
                }
                Section { NavigationLink(value: LoRaRoute.security) { Label(psstTr("lora_how_encrypted"), systemImage: "lock.doc") } }
            }
            .navigationTitle("LoRa")
            .navigationDestination(for: LoRaRoute.self) { route in
                switch route {
                case .scan: DeviceScanView(model: model) { if path.last == .scan { path.removeLast() } }
                case .nodes: NodesView(model: model)
                case .myCard: MyCardView(model: model)
                case .linkCard: LinkCardView(model: model)
                case .peers: PeersView(model: model)
                case .security: SecurityInfoView()
                case .conversation(let c): ConversationView(model: model, conversation: c)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(psstTr("lora_close"), action: onClose) }
            }
            .onAppear { model.reconnectIfNeeded() }
        }
    }

    private var channelList: [Conversation] {
        let chans = model.client.channels.keys.sorted().map { Conversation.channel($0) }
        return chans.isEmpty ? [.channel(0)] : chans
    }
}

struct DeviceSection: View {
    @ObservedObject var model: LabMeshModel
    let onScan: () -> Void

    var body: some View {
        Section {
            if let p = model.bluetoothProblem {
                Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Image(systemName: icon).foregroundStyle(color).font(.title2)
                VStack(alignment: .leading) {
                    Text(model.rememberedDeviceName ?? psstTr("lora_no_device")).font(.headline)
                    Text(stateText).font(.subheadline).foregroundStyle(.secondary)
                    if let me = model.client.myNode, model.clientState == .ready {
                        Text("\(me.displayName) · \(me.userID)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let b = model.battery {
                    Label(b > 100 ? psstTr("lora_powered") : "\(b) %", systemImage: batteryIcon(b)).font(.caption).labelStyle(.titleAndIcon)
                }
            }
            if model.clientState == .ready, let region = model.client.region {
                LabeledContent(psstTr("lora_region_preset"), value: "\(String(describing: region).uppercased()) · \(model.client.modemPreset ?? "")")
                if region == .unset {
                    Button(psstTr("lora_region_unset")) { model.client.setRegionEU868IfUnset() }
                }
                if let fw = model.client.firmwareVersion { LabeledContent(psstTr("lora_firmware"), value: fw) }
                if let r = model.bleRSSI { LabeledContent(psstTr("lora_bt_signal"), value: "\(r) dBm") }
            }
            switch model.clientState {
            case .ready, .configuring, .connecting:
                Button(psstTr("lora_disconnect"), role: .destructive) { model.disconnect() }
            case .disconnected:
                if model.hasRememberedDevice { Button(psstTr("lora_reconnect")) { model.reconnectIfNeeded() } }
            }
            Button(model.hasRememberedDevice ? psstTr("lora_choose_other") : psstTr("lora_search_bt"), action: onScan)
        } header: { Text(psstTr("lora_device_header")) } footer: {
            if let e = model.lastEvent { Text(e) }
        }
    }

    var stateText: String {
        switch model.clientState {
        case .ready: psstTr("lora_state_ready")
        case .configuring: psstTr("lora_state_configuring")
        case .connecting: psstTr("lora_state_connecting")
        case .disconnected(let why): why.map { psstTr("lora_state_disconnected_why", $0) } ?? psstTr("lora_state_disconnected")
        }
    }

    var icon: String { model.clientState == .ready ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash" }
    var color: Color { model.clientState == .ready ? .green : .secondary }

    func batteryIcon(_ b: Int) -> String {
        switch b { case 101...: "bolt.fill"; case 75...: "battery.100"; case 50...: "battery.75"; case 25...: "battery.50"; case 10...: "battery.25"; default: "battery.0" }
    }
}

// MARK: - Scan

struct DeviceScanView: View {
    @ObservedObject var model: LabMeshModel
    let onDone: () -> Void

    var body: some View {
            List {
                Section {
                    if model.radios.isEmpty {
                        HStack { ProgressView(); Text(psstTr("lora_searching")).foregroundStyle(.secondary) }
                    }
                    ForEach(model.radios) { r in
                        Button {
                            model.connect(r)
                            onDone()
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text(r.name)
                                Spacer()
                                Text("\(r.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(psstTr("lora_scan_footer"))
                }
            }
            .navigationTitle(psstTr("lora_devices"))
            .onAppear { model.startScan() }
            .onDisappear { model.stopScan() }
    }
}

// MARK: - Nodes

struct NodesView: View {
    @ObservedObject var model: LabMeshModel

    var body: some View {
        let nodes = model.client.labState.nodes.values.filter { $0.num != model.client.myNodeNum }
            .sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
        List {
            if nodes.isEmpty { Text(psstTr("lora_no_nodes")).foregroundStyle(.secondary) }
            ForEach(nodes) { n in
                NavigationLink(value: LoRaRoute.conversation(.direct(n.num))) { NodeRow(model: model, node: n) }
            }
        }
        .navigationTitle("Uzly (\(nodes.count))")
    }
}

struct NodeRow: View {
    @ObservedObject var model: LabMeshModel
    let node: MeshNode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(node.displayName).font(.headline)
                if !node.shortName.isEmpty { Text(node.shortName).font(.caption).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                if model.isLinked(node.num) { Image(systemName: "lock.fill").foregroundStyle(.green).accessibilityLabel(psstTr("lora_linked_contact_a11y")) }
            }
            Text("\(node.userID) · \(node.hwModel)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(node.lastHeard.map(relative) ?? psstTr("lora_never"), systemImage: "clock")
                if let s = node.snr { Label(String(format: "SNR %.1f dB", s), systemImage: "waveform") }
                if let r = node.rssi { Text("\(r) dBm") }
                if let h = node.hopsAway { Text(h == 0 ? psstTr("lora_direct") : "\(h) skok(y)") }
                if let b = node.batteryLevel { Text(b > 100 ? "⚡︎" : "\(b) %") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: - Conversations

struct ConversationRow: View {
    @ObservedObject var model: LabMeshModel
    let conversation: Conversation

    var body: some View {
        let last = model.client.messages(in: conversation).last
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: conversationIcon)
                Text(model.title(for: conversation)).font(.headline)
                if case .direct(let n) = conversation, model.isLinked(n) { Image(systemName: "lock.fill").foregroundStyle(.green) }
            }
            if let last { Text(last.text).lineLimit(1).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    var conversationIcon: String { if case .channel = conversation { "dot.radiowaves.left.and.right" } else { "person" } }
}

public struct ConversationView: View {
    @ObservedObject var model: LabMeshModel
    let conversation: Conversation
    @State private var text = ""
    @State private var encrypted = true
    @State private var error: String?

    public init(model: LabMeshModel, conversation: Conversation) {
        self.model = model
        self.conversation = conversation
    }

    var linked: Bool { if case .direct(let n) = conversation { model.isLinked(n) } else { false } }
    var useEncryption: Bool { linked && encrypted }
    var limit: Int { useEncryption ? LabFormat.maxTextBytes() : MeshClient.maxPlainTextBytes }
    var bytes: Int { Data(text.utf8).count }

    public var body: some View {
        let messages = model.client.messages(in: conversation)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        header
                        ForEach(messages) { m in MessageBubble(model: model, message: m).id(m.id) }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in if let l = messages.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
                .onAppear { if let l = messages.last { proxy.scrollTo(l.id, anchor: .bottom) } }
            }
            Divider()
            composer
        }
        .navigationTitle(model.title(for: conversation))
        .alert(psstTr("lora_not_sent_title"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(psstTr("lora_ok")) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder var header: some View {
        switch conversation {
        case .channel(let i):
            SecurityNote(security: model.client.channels[i]?.security ?? .meshtasticChannel,
                         text: psstTr("lora_channel_note"))
        case .direct(let n):
            if linked {
                SecurityNote(security: .psstE2E, text: psstTr("lora_linked_note", model.title(for: conversation)))
            } else {
                SecurityNote(security: model.client.node(n)?.publicKey != nil ? .meshtasticPKI : .meshtasticChannel,
                             text: psstTr("lora_unlinked_note"))
            }
        }
    }

    var composer: some View {
        VStack(spacing: 6) {
            if linked {
                Toggle(isOn: $encrypted) { Label(psstTr("lora_psst_encryption"), systemImage: encrypted ? "lock.fill" : "lock.open") }
                    .font(.footnote)
            }
            HStack(alignment: .bottom) {
                TextField(psstTr("lora_message_placeholder"), text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button {
                    do {
                        try model.send(text, to: conversation, encrypted: useEncryption)
                        text = ""
                    } catch {
                        self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    }
                } label: { Image(systemName: "paperplane.fill").font(.title3) }
                .disabled(text.isEmpty || bytes > limit || model.clientState != .ready)
            }
            HStack {
                Text(model.clientState == .ready ? "" : psstTr("lora_radio_not_connected"))
                Spacer()
                Text(counterText).foregroundStyle(bytes > limit ? .red : .secondary)
            }
            .font(.caption2)
        }
        .padding(10)
    }

    var counterText: String {
        if useEncryption {
            let frames = max(1, Int((Double(bytes + 17) / Double(LabFormat.maxPartBytes)).rounded(.up)))
            return "\(bytes)/\(limit) B · \(frames) LoRa paket(y)"
        }
        return "\(bytes)/\(limit) B"
    }
}

struct SecurityNote: View {
    let security: MessageSecurity
    let text: String
    var body: some View {
        HStack(alignment: .top) {
            SecurityBadge(security: security)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

public struct SecurityBadge: View {
    let security: MessageSecurity
    public init(security: MessageSecurity) { self.security = security }
    public var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel(Text(psstTr("lora_encryption_a11y", title)))
    }

    var title: String {
        switch security {
        case .psstE2E: psstTr("lora_psst_encryption")
        case .meshtasticPKI: psstTr("lora_badge_pki")
        case .meshtasticChannel: psstTr("lora_badge_channel")
        case .meshtasticDefaultKey: psstTr("lora_badge_default")
        case .none: psstTr("lora_badge_none")
        }
    }

    var icon: String {
        switch security {
        case .psstE2E: "lock.shield.fill"
        case .meshtasticPKI, .meshtasticChannel: "lock"
        case .meshtasticDefaultKey, .none: "lock.open"
        }
    }

    var color: Color {
        switch security {
        case .psstE2E: .green
        case .meshtasticPKI, .meshtasticChannel: .orange
        case .meshtasticDefaultKey, .none: .red
        }
    }
}

struct MessageBubble: View {
    @ObservedObject var model: LabMeshModel
    let message: LoRaMessage

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 40) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 3) {
                if !message.outgoing, case .channel = message.conversation {
                    Text(model.client.node(message.fromNode)?.displayName ?? MeshNode.userID(message.fromNode))
                        .font(.caption.weight(.semibold))
                }
                Text(message.text)
                    .padding(10)
                    .background(message.outgoing ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 6) {
                    SecurityBadge(security: message.security)
                    if message.chunks > 1 { Text(psstTr("lora_chunks", message.chunks)).font(.caption2).foregroundStyle(.secondary) }
                    Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    if message.outgoing { DeliveryLabel(state: message.state, chunks: message.chunks, acked: message.ackedPacketIDs.count) }
                    if !message.outgoing, let s = message.rxSnr, s != 0 { Text(String(format: "SNR %.1f", s)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if !message.outgoing { Spacer(minLength: 40) }
        }
    }
}

struct DeliveryLabel: View {
    let state: DeliveryState
    let chunks: Int
    let acked: Int
    var body: some View {
        switch state {
        case .queued: Label(psstTr("lora_queued"), systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent: Label(chunks > 1 ? psstTr("lora_sent_parts", acked, chunks) : psstTr("lora_sent"), systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
        case .delivered: Label(psstTr("lora_delivered"), systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .failed(let why): Label("zlyhalo: \(why)", systemImage: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
        }
    }
}

// MARK: - Keys, QR, peers

struct MyCardView: View {
    @ObservedObject var model: LabMeshModel
    var body: some View {
        List {
            if let card = model.myCard() {
                Section {
                    if let img = qrImage(card.encoded) {
                        img.interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260).frame(maxWidth: .infinity)
                    }
                    LabeledContent(psstTr("lora_node"), value: MeshNode.userID(card.nodeNum))
                    LabeledContent(psstTr("lora_fingerprint"), value: LabIdentity.fingerprint(card.publicKey)).font(.footnote.monospaced())
                    if let mx = card.matrixUserID { LabeledContent(psstTr("lora_account", psstAppName), value: mx) }
                } footer: {
                    Text(psstTr("lora_card_footer"))
                }
                Section { ShareLink(item: card.encoded) { Label(psstTr("lora_share_card"), systemImage: "square.and.arrow.up") } }
            } else {
                Text(psstTr("lora_connect_first")).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(psstTr("lora_my_key"))
    }
}

func qrImage(_ s: String) -> Image? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(s.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return Image(decorative: cg, scale: 1)
}

struct LinkCardView: View {
    @ObservedObject var model: LabMeshModel
    @State private var pasted = ""
    @State private var result: String?
    @State private var scanning = false

    var body: some View {
        List {
            #if os(iOS)
            Section {
                if scanning {
                    // inline, not a sheet (L1c)
                    QRScannerView { code in
                        scanning = false
                        handle(code)
                    }
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
                    Button(psstTr("lora_stop_scan")) { scanning = false }
                } else {
                    Button { scanning = true } label: { Label(psstTr("lora_scan_qr"), systemImage: "camera") }
                }
            } footer: { Text(psstTr("lora_camera_footer")) }
            #endif
            Section(psstTr("lora_paste_card")) {
                TextField("psstlab1:…", text: $pasted, axis: .vertical).font(.footnote.monospaced())
                Button(psstTr("lora_link")) { handle(pasted) }.disabled(!pasted.contains(PeerCard.prefix))
            }
            if let result { Section { Text(result) } }
        }
        .navigationTitle(psstTr("lora_link_qr_title"))
    }

    func handle(_ text: String) {
        if let card = model.linkScanned(text) {
            result = psstTr("lora_linked_result", card.name.isEmpty ? MeshNode.userID(card.nodeNum) : card.name, MeshNode.userID(card.nodeNum), LabIdentity.fingerprint(card.publicKey))
        } else {
            result = psstTr("lora_invalid_card")
        }
    }
}

struct PeersView: View {
    @ObservedObject var model: LabMeshModel
    var body: some View {
        let peers = model.client.labState.peers.values.sorted { $0.linkedAt > $1.linkedAt }
        List {
            if peers.isEmpty { Text(psstTr("lora_no_peers")).foregroundStyle(.secondary) }
            ForEach(peers) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.card.name.isEmpty ? MeshNode.userID(p.card.nodeNum) : p.card.name).font(.headline)
                    if let mx = p.card.matrixUserID { Text(mx).font(.caption) }
                    Text(psstTr("lora_node_key", MeshNode.userID(p.card.nodeNum), LabIdentity.fingerprint(p.card.publicKey))).font(.caption2.monospaced())
                    Text(psstTr(p.source == "matrix" ? "lora_linked_via_chat" : "lora_linked_via_qr", relative(p.linkedAt))).font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions { Button(psstTr("lora_unlink"), role: .destructive) { model.unlink(p.card.nodeNum) } }
            }
        }
        .navigationTitle(psstTr("lora_linked_contacts"))
    }
}

struct SecurityInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    Text(psstTr("lora_enc_meshtastic_title")).font(.headline)
                    Text(psstTr("lora_enc_meshtastic_body"))
                }
                Group {
                    Text(psstTr("lora_enc_psst_title")).font(.headline)
                    Text(psstTr("lora_enc_psst_body"))
                }
            }
            .padding()
        }
        .navigationTitle(psstTr("lora_encryption"))
    }
}
