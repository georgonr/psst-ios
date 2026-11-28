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
                Section("Rozhovory") {
                    ForEach(channelList, id: \.self) { c in
                        NavigationLink(value: LoRaRoute.conversation(c)) { ConversationRow(model: model, conversation: c) }
                    }
                    ForEach(model.conversations.filter { if case .direct = $0 { true } else { false } }, id: \.self) { c in
                        NavigationLink(value: LoRaRoute.conversation(c)) { ConversationRow(model: model, conversation: c) }
                    }
                    NavigationLink(value: LoRaRoute.nodes) {
                        Label("Nová priama správa — zoznam uzlov", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                Section {
                    NavigationLink(value: LoRaRoute.myCard) { Label("Môj kľúč a QR kód", systemImage: "qrcode") }
                    NavigationLink(value: LoRaRoute.linkCard) { Label("Prepojiť kontakt cez QR kód", systemImage: "qrcode.viewfinder") }
                    NavigationLink(value: LoRaRoute.peers) {
                        Label("Prepojené kontakty (\(model.client.labState.peers.count))", systemImage: "person.2.badge.key")
                    }
                } header: { Text("psst šifrovanie") } footer: {
                    Text("Priame správy medzi dvoma používateľmi psst lab sú šifrované naším kľúčom (X25519 + ChaCha20-Poly1305). Kontakt prepojíte tlačidlom „Prepojiť s LoRa“ v detaile psst rozhovoru alebo QR kódom.")
                }
                Section { NavigationLink(value: LoRaRoute.security) { Label("Ako sú LoRa správy šifrované", systemImage: "lock.doc") } }
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
                ToolbarItem(placement: .cancellationAction) { Button("Zavrieť", action: onClose) }
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
                    Text(model.rememberedDeviceName ?? "Žiadne zariadenie").font(.headline)
                    Text(stateText).font(.subheadline).foregroundStyle(.secondary)
                    if let me = model.client.myNode, model.clientState == .ready {
                        Text("\(me.displayName) · \(me.userID)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let b = model.battery {
                    Label(b > 100 ? "napájanie" : "\(b) %", systemImage: batteryIcon(b)).font(.caption).labelStyle(.titleAndIcon)
                }
            }
            if model.clientState == .ready, let region = model.client.region {
                LabeledContent("Región / profil", value: "\(String(describing: region).uppercased()) · \(model.client.modemPreset ?? "")")
                if region == .unset {
                    Button("Región nie je nastavený — nastaviť EU_868") { model.client.setRegionEU868IfUnset() }
                }
                if let fw = model.client.firmwareVersion { LabeledContent("Firmvér", value: fw) }
                if let r = model.bleRSSI { LabeledContent("Signál Bluetooth", value: "\(r) dBm") }
            }
            switch model.clientState {
            case .ready, .configuring, .connecting:
                Button("Odpojiť", role: .destructive) { model.disconnect() }
            case .disconnected:
                if model.hasRememberedDevice { Button("Pripojiť znova") { model.reconnectIfNeeded() } }
            }
            Button(model.hasRememberedDevice ? "Vybrať iné zariadenie…" : "Vyhľadať zariadenia cez Bluetooth…", action: onScan)
        } header: { Text("Zariadenie Meshtastic") } footer: {
            if let e = model.lastEvent { Text(e) }
        }
    }

    var stateText: String {
        switch model.clientState {
        case .ready: "Pripojené"
        case .configuring: "Načítavam nastavenia a uzly…"
        case .connecting: "Pripájam… (pri prvom spojení zadajte PIN z displeja rádia)"
        case .disconnected(let why): why.map { "Odpojené: \($0)" } ?? "Odpojené"
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
                        HStack { ProgressView(); Text("Hľadám rádiá Meshtastic…").foregroundStyle(.secondary) }
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
                    Text("""
                    Zobrazujú sa len zariadenia so službou Meshtastic. Ak tu rádio nie je: zapnite na ňom Bluetooth (Meshtastic → Config → Bluetooth), \
                    odpojte ho od iného telefónu alebo appky Meshtastic (rádio prijme naraz len jedno spojenie) a priblížte ho. \
                    Pri prvom pripojení iPhone vypýta PIN — býva na displeji rádia, inak je to pevný PIN z nastavení rádia (často 123456).
                    """)
                }
            }
            .navigationTitle("Zariadenia")
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
            if nodes.isEmpty { Text("Rádio zatiaľ nepozná žiadne iné uzly.").foregroundStyle(.secondary) }
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
                if model.isLinked(node.num) { Image(systemName: "lock.fill").foregroundStyle(.green).accessibilityLabel("prepojený psst lab kontakt") }
            }
            Text("\(node.userID) · \(node.hwModel)").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(node.lastHeard.map(relative) ?? "nikdy", systemImage: "clock")
                if let s = node.snr { Label(String(format: "SNR %.1f dB", s), systemImage: "waveform") }
                if let r = node.rssi { Text("\(r) dBm") }
                if let h = node.hopsAway { Text(h == 0 ? "priamo" : "\(h) skok(y)") }
                if let b = node.batteryLevel { Text(b > 100 ? "⚡︎" : "\(b) %") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "sk")
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
        .alert("Správa sa neodoslala", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder var header: some View {
        switch conversation {
        case .channel(let i):
            SecurityNote(security: model.client.channels[i]?.security ?? .meshtasticChannel,
                         text: "Kanál: správu dostanú všetky rádiá s rovnakým kanálom v dosahu siete. psst šifrovanie sa v kanáli nepoužíva.")
        case .direct(let n):
            if linked {
                SecurityNote(security: .psstE2E, text: "Prepojený kontakt psst lab — správy môže prečítať len \(model.title(for: conversation)).")
            } else {
                SecurityNote(security: model.client.node(n)?.publicKey != nil ? .meshtasticPKI : .meshtasticChannel,
                             text: "Uzol nie je prepojený s psst lab — správa ide len so šifrovaním Meshtastic. Prepojte kontakt cez psst rozhovor alebo QR kód.")
            }
        }
    }

    var composer: some View {
        VStack(spacing: 6) {
            if linked {
                Toggle(isOn: $encrypted) { Label("psst šifrovanie", systemImage: encrypted ? "lock.fill" : "lock.open") }
                    .font(.footnote)
            }
            HStack(alignment: .bottom) {
                TextField("LoRa správa", text: $text, axis: .vertical)
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
                Text(model.clientState == .ready ? "" : "Rádio nie je pripojené")
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
            .accessibilityLabel(Text("Šifrovanie: \(title)"))
    }

    var title: String {
        switch security {
        case .psstE2E: "psst šifrovanie"
        case .meshtasticPKI: "len Meshtastic (PKI)"
        case .meshtasticChannel: "len Meshtastic (kľúč kanála)"
        case .meshtasticDefaultKey: "verejný kľúč kanála"
        case .none: "nešifrované"
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
                    if message.chunks > 1 { Text("\(message.chunks) pakety").font(.caption2).foregroundStyle(.secondary) }
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
        case .queued: Label("odosiela sa", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
        case .sent: Label(chunks > 1 ? "odoslané \(acked)/\(chunks)" : "odoslané", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
        case .delivered: Label("potvrdené", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
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
                    LabeledContent("LoRa uzol", value: MeshNode.userID(card.nodeNum))
                    LabeledContent("Odtlačok kľúča", value: LabIdentity.fingerprint(card.publicKey)).font(.footnote.monospaced())
                    if let mx = card.matrixUserID { LabeledContent("psst účet", value: mx) }
                } footer: {
                    Text("Druhý používateľ psst lab naskenuje tento kód (LoRa → Prepojiť kontakt cez QR kód). Kód obsahuje len verejný kľúč — súkromný kľúč nikdy neopustí Keychain tohto iPhonu.")
                }
                Section { ShareLink(item: card.encoded) { Label("Zdieľať kartu ako text", systemImage: "square.and.arrow.up") } }
            } else {
                Text("Najprv pripojte svoje rádio Meshtastic — karta obsahuje číslo vášho LoRa uzla.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Môj kľúč")
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
                    Button("Zastaviť skenovanie") { scanning = false }
                } else {
                    Button { scanning = true } label: { Label("Naskenovať QR kód", systemImage: "camera") }
                }
            } footer: { Text("Kamera sa použije len na načítanie QR kódu druhého používateľa psst lab.") }
            #endif
            Section("alebo vložte kartu (psstlab1:…)") {
                TextField("psstlab1:…", text: $pasted, axis: .vertical).font(.footnote.monospaced())
                Button("Prepojiť") { handle(pasted) }.disabled(!pasted.contains(PeerCard.prefix))
            }
            if let result { Section { Text(result) } }
        }
        .navigationTitle("Prepojiť cez QR")
    }

    func handle(_ text: String) {
        if let card = model.linkScanned(text) {
            result = "Prepojené: \(card.name.isEmpty ? MeshNode.userID(card.nodeNum) : card.name) · uzol \(MeshNode.userID(card.nodeNum)) · kľúč \(LabIdentity.fingerprint(card.publicKey)). Porovnajte odtlačok s obrazovkou druhého telefónu."
        } else {
            result = "Toto nie je platná karta psst lab."
        }
    }
}

struct PeersView: View {
    @ObservedObject var model: LabMeshModel
    var body: some View {
        let peers = model.client.labState.peers.values.sorted { $0.linkedAt > $1.linkedAt }
        List {
            if peers.isEmpty { Text("Zatiaľ žiadne prepojené kontakty.").foregroundStyle(.secondary) }
            ForEach(peers) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.card.name.isEmpty ? MeshNode.userID(p.card.nodeNum) : p.card.name).font(.headline)
                    if let mx = p.card.matrixUserID { Text(mx).font(.caption) }
                    Text("uzol \(MeshNode.userID(p.card.nodeNum)) · kľúč \(LabIdentity.fingerprint(p.card.publicKey))").font(.caption2.monospaced())
                    Text("prepojené \(p.source == "matrix" ? "cez psst rozhovor" : "QR kódom") \(relative(p.linkedAt))").font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Zrušiť", role: .destructive) { model.unlink(p.card.nodeNum) } }
            }
        }
        .navigationTitle("Prepojené kontakty")
    }
}

struct SecurityInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    Text("Šifrovanie Meshtastic").font(.headline)
                    Text("""
                    • Kanál: všetky rádiá kanála zdieľajú jeden kľúč (AES-128/256 v režime CTR, bez overenia integrity). Predvolený kanál „LongFast“ používa verejne známy kľúč „AQ==“ — takú správu si prečíta ktokoľvek s appkou Meshtastic.
                    • Priama správa (firmvér 2.5+): rádiá ju šifrujú kľúčmi uzlov (X25519 + AES-256-CCM). Prečíta ju cieľové rádio a každý telefón, ktorý je k nemu pripojený.
                    • Hlavička paketu (odosielateľ, príjemca, ID, počet skokov) šifrovaná nie je — sieť vidí, kto komu píše a kedy.
                    """)
                }
                Group {
                    Text("psst šifrovanie (navyše)").font(.headline)
                    Text("""
                    • Každý používateľ psst lab má vlastný pár kľúčov X25519 v Keychain iPhonu (neopúšťa ho, nezálohuje sa).
                    • Text priamej správy prepojenému kontaktu sa zašifruje ChaCha20-Poly1305 kľúčom odvodeným z oboch kľúčov (HKDF-SHA256, zvlášť pre každý smer). Prečítať ho vie len druhý telefón — ani rádiá, ani ostatní v sieti.
                    • Overenie odosielateľa: správu vie vytvoriť len držiteľ súkromného kľúča kontaktu. Počítadlo správ chráni proti opakovaniu (zopakovaná správa sa odmietne).
                    • Dlhšia správa sa rozdelí na viac LoRa paketov (max. 8) a druhý telefón ju poskladá.
                    • Kľúče a väzbu „psst účet ↔ LoRa uzol“ si vymeníte cez šifrovaný psst rozhovor alebo QR kódom osobne. Porovnajte odtlačky kľúča.
                    • Obmedzenia: bez forward secrecy (kompromitovaný kľúč odhalí aj staré zachytené správy), metadáta Meshtastic hlavičky ostávajú viditeľné, vlastnej správe v kanáli psst šifrovanie nepridáva.
                    """)
                }
            }
            .padding()
        }
        .navigationTitle("Šifrovanie")
    }
}
