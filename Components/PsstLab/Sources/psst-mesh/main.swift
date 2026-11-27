// PSST (L1): psst-mesh — the psst lab Meshtastic layer (PsstMesh) over a serial port on the Mac.
//
//   psst-mesh info      --port /dev/cu.usbserial-0001
//   psst-mesh listen    --port P [--seconds 60]
//   psst-mesh send      --port P --channel 0 --text "…"          broadcast, waits for the implicit ACK
//   psst-mesh send      --port P --to '!a1b2c3d4' --text "…"     direct, waits for the ACK of the node
//   psst-mesh card      --port P [--name N]                      prints this side's psst lab card (psstlab1:…)
//   psst-mesh link      --card psstlab1:…                        stores a peer (key + node)
//   psst-mesh send-enc  --port P --to '!a1b2c3d4' --text "…"     psst E2E (chunked when long), waits for all ACKs
//   psst-mesh test      --port P [--to '!node'] [--peer-card psstlab1:…] [--report file.md]   full device test
//
// State (messages, peers, counters) and the private key live in --state (default ~/.psst-lab-mesh), not in the repo.
// The tool never changes radio settings, except: if the region is UNSET it sets EU_868 (DECISIONS L1-08).
import Foundation
import MeshtasticProtobufs
import PsstMesh
import PsstMeshSerial

@MainActor
struct Args {
    var cmd = ""
    var opts: [String: String] = [:]
    init() {
        var a = Array(CommandLine.arguments.dropFirst())
        cmd = a.isEmpty ? "help" : a.removeFirst()
        while !a.isEmpty {
            let k = a.removeFirst()
            guard k.hasPrefix("--") else { continue }
            opts[String(k.dropFirst(2))] = a.first.map { $0.hasPrefix("--") ? "" : a.removeFirst() } ?? ""
        }
    }
    subscript(_ k: String) -> String? { opts[k] }
}

@MainActor
final class Tool {
    let args: Args
    let stateDir: URL
    var client: MeshClient!
    var report: [String] = []
    var failures = 0

    init(args: Args) {
        self.args = args
        stateDir = URL(fileURLWithPath: args["state"] ?? (NSHomeDirectory() + "/.psst-lab-mesh"))
    }

    func out(_ s: String) {
        print(s)
        report.append(s)
    }

    func check(_ ok: Bool, _ what: String) {
        out("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    func makeClient() -> MeshClient {
        let port = args["port"] ?? Tool.findPort() ?? "/dev/cu.usbserial-0001"
        let t = SerialTransport(path: port)
        if args["debug"] != nil { t.onDebugLine = { print("  [radio] \($0)") } }
        let keys = FileKeyStore(url: stateDir.appendingPathComponent("x25519.key"))
        let c = MeshClient(transport: t, store: LabStateStore(directory: stateDir), identity: { try keys.loadOrCreateIdentity() })
        c.onEvent = { print("  · \($0)") }
        c.onIncomingMessage = { m in
            print("  ← [\(m.security.rawValue)] \(MeshNode.userID(m.fromNode)) \(m.conversation): \(m.text)")
        }
        return c
    }

    static func findPort() -> String? {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.SLAB") || $0.hasPrefix("cu.wchusbserial") }
            .sorted().first.map { "/dev/" + $0 }
    }

    func wait(_ seconds: Double, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return cond()
    }

    func connect() async -> Bool {
        client = makeClient()
        client.connect()
        let ok = await wait(40) { client.state == .ready }
        if !ok { print("radio did not finish sending its configuration (state \(client.state))") }
        return ok
    }

    func parseNode(_ s: String?) -> UInt32? {
        guard var s, !s.isEmpty else { return nil }
        if s.hasPrefix("!") { s.removeFirst(); return UInt32(s, radix: 16) }
        return UInt32(s) ?? UInt32(s, radix: 16)
    }

    func printInfo() {
        let me = client.myNodeNum.map(MeshNode.userID) ?? "?"
        out("my node: \(me) \(client.myNode?.longName ?? "") (\(client.myNode?.hwModel ?? "")), firmware \(client.firmwareVersion ?? "?")")
        out("region: \(client.region.map { String(describing: $0) } ?? "?"), preset \(client.modemPreset ?? "?")")
        for ch in client.channels.values.sorted(by: { $0.index < $1.index }) {
            let kind = switch ch.security {
            case .none: "no encryption"
            case .meshtasticDefaultKey: "default published key (AQ==)"
            default: "own key \(ch.pskLength * 8)-bit"
            }
            out("channel \(ch.index) \(ch.role) '\(ch.name.isEmpty ? "(preset name)" : ch.name)': \(kind)")
        }
        let nodes = client.labState.nodes.values.filter { $0.num != client.myNodeNum }.sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
        out("nodes (\(nodes.count) besides mine):")
        let f = ISO8601DateFormatter()
        for n in nodes {
            out("  \(n.userID) \(n.longName.isEmpty ? "?" : n.longName) [\(n.shortName)] \(n.hwModel) last heard \(n.lastHeard.map { f.string(from: $0) } ?? "—") snr \(n.snr.map { String(format: "%.1f", $0) } ?? "—") hops \(n.hopsAway.map(String.init) ?? "—") pki \(n.publicKey != nil ? "yes" : "no")\(n.batteryLevel.map { " battery \($0)%" } ?? "")")
        }
    }

    func waitFinal(_ id: UUID, seconds: Double) async -> LoRaMessage? {
        _ = await wait(seconds) {
            guard let m = client.labState.messages.first(where: { $0.id == id }) else { return false }
            if case .direct = m.conversation { return m.state.isFinal }
            return m.state != .queued
        }
        return client.labState.messages.first { $0.id == id }
    }

    func describe(_ m: LoRaMessage?) -> String {
        guard let m else { return "missing" }
        return "\(m.state) (packets \(m.packetIDs.count), acked by node \(m.ackedPacketIDs.count), relayed \(m.relayedPacketIDs.count))"
    }

    // MARK: commands

    func run() async -> Int32 {
        switch args.cmd {
        case "info":
            guard await connect() else { return 1 }
            printInfo()
        case "listen":
            guard await connect() else { return 1 }
            printInfo()
            print("listening…")
            try? await Task.sleep(nanoseconds: UInt64((Double(args["seconds"] ?? "60") ?? 60) * 1e9))
        case "send":
            guard await connect() else { return 1 }
            let text = args["text"] ?? "psst lab test \(Date())"
            do {
                let conv: Conversation = parseNode(args["to"]).map { .direct($0) } ?? .channel(Int(args["channel"] ?? "0") ?? 0)
                let m = try client.sendText(text, to: conv)
                print("sent \(m.packetIDs) → waiting for ACK…")
                print(describe(await waitFinal(m.id, seconds: 150)))
            } catch { print("error: \(error)"); return 1 }
        case "card":
            guard await connect() else { return 1 }
            print(client.myCard(matrixUserID: args["mxid"], name: args["name"] ?? "psst-mesh")?.encoded ?? "no card")
        case "link":
            guard let s = args["card"], let card = PeerCard.find(in: s) else { print("invalid card"); return 2 }
            client = makeClient()
            client.link(card: card, source: "cli")
            print("linked \(MeshNode.userID(card.nodeNum)) \(card.name) key \(LabIdentity.fingerprint(card.publicKey))")
        case "send-enc":
            guard await connect(), let to = parseNode(args["to"]) else { return 1 }
            do {
                let m = try client.sendEncrypted(args["text"] ?? "psst lab encrypted \(Date())", to: to)
                print("sent \(m.chunks) frame(s) → waiting for ACKs…")
                print(describe(await waitFinal(m.id, seconds: 240)))
            } catch { print("error: \(error)"); return 1 }
        case "test":
            return await deviceTest()
        default:
            print("usage: see the header of Sources/psst-mesh/main.swift")
        }
        client?.disconnect()
        return 0
    }

    /// The real-device test of DECISIONS L1 / LAB-LORA.md: connection, nodes, channel + direct text with ACK,
    /// psst E2E single + chunked with ACKs, and — with --peer-card of a second psst lab side — decrypting a reply.
    func deviceTest() async -> Int32 {
        let started = Date()
        out("# psst-mesh device test \(ISO8601DateFormatter().string(from: started))")
        let ok = await connect()
        check(ok, "connect over serial (\(client.transport is SerialTransport ? (client.transport as! SerialTransport).path : "?")), want_config → config_complete")
        guard ok else { return finish() }
        printInfo()
        check(client.myNodeNum != nil, "my_info: own node number")
        check(client.region != nil && client.region != .unset, "LoRa region is set (\(client.region.map { String(describing: $0) } ?? "?"))")
        if client.region == .unset {
            client.setRegionEU868IfUnset()
            out("region was UNSET → EU_868 requested (radio reboots)")
            return finish()
        }
        let others = client.labState.nodes.values.filter { $0.num != client.myNodeNum }
        check(!others.isEmpty, "node DB contains other nodes (\(others.count))")
        let target = parseNode(args["to"]) ?? others.sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }.first?.num
        guard let target else { out("no second node known — cannot test direct messages"); return finish() }
        out("target node: \(MeshNode.userID(target)) \(client.node(target)?.longName ?? "")")

        // 1. channel broadcast
        do {
            let m = try client.sendText("psst lab test: kanál \(Int(started.timeIntervalSince1970) % 10000)", to: .channel(0))
            let r = await waitFinal(m.id, seconds: 90)
            check(r?.state == .sent || r?.state == .delivered, "channel 0 broadcast: \(describe(r))")
        } catch { check(false, "channel broadcast: \(error)") }

        // 2. plain direct message
        do {
            let m = try client.sendText("psst lab test: priama správa", to: .direct(target))
            let r = await waitFinal(m.id, seconds: 150)
            check(r?.state == .delivered, "direct text to \(MeshNode.userID(target)) with ACK from the node: \(describe(r))")
        } catch { check(false, "direct text: \(error)") }

        // 3. psst E2E: the target node does not run psst lab, so we link it with a test key pair held by this tool
        //    (the node only relays/ACKs the PRIVATE_APP frames; it cannot read them).
        let peerID: LabIdentity
        let peerKeyFile = stateDir.appendingPathComponent("test-peer-\(MeshNode.userID(target)).key")
        peerID = (try? FileKeyStore(url: peerKeyFile).loadOrCreateIdentity()) ?? LabIdentity()
        let peerCard = args["peer-card"].flatMap(PeerCard.find(in:))
            ?? PeerCard(nodeNum: target, publicKey: peerID.publicKey, matrixUserID: nil, name: "test peer")
        client.link(card: peerCard, source: "test")
        for (label, text) in [("single-frame", "Ahoj, toto je šifrovaná správa psst lab 🔒"),
                              ("chunked", String(repeating: "Dlhšia šifrovaná správa psst lab rozdelená na viac LoRa paketov. ", count: 7))] {
            do {
                let m = try client.sendEncrypted(text, to: target)
                let r = await waitFinal(m.id, seconds: 300)
                check(r?.state == .delivered, "psst E2E \(label) (\(Data(text.utf8).count) B → \(m.chunks) frame(s)) to \(MeshNode.userID(target)), all frames ACKed: \(describe(r))")
                // the frames that went on air decrypt with the peer's key (what the other phone would do)
                if args["peer-card"] == nil, let me = client.myNodeNum, let myID = client.myIdentity {
                    let myCard = PeerCard(nodeNum: me, publicKey: myID.publicKey, matrixUserID: nil, name: "me")
                    let frames = try LabCrypto.seal(text: text, counter: client.labState.peers[target]!.sendCounter,
                                                    identity: myID, myNode: me, peer: peerCard)
                    var inbox = LabInbox()
                    var result: LabInbox.Result?
                    for f in frames.reversed() { result = try inbox.receive(frame: f, from: myCard, identity: peerID, myNode: target) }
                    check(result == .message(text: text, counter: client.labState.peers[target]!.sendCounter, chunks: frames.count),
                          "peer side reassembles + decrypts the \(label) message (same frames as sent)")
                }
            } catch { check(false, "psst E2E \(label): \(error)") }
        }

        // 4. receiving: only possible when the other side runs psst lab (--peer-card) — wait for its encrypted reply
        if args["peer-card"] != nil {
            let before = client.labState.messages.count
            out("waiting up to 180 s for an encrypted message from \(MeshNode.userID(target))…")
            let got = await wait(180) {
                client.labState.messages.dropFirst(before).contains { !$0.outgoing && $0.security == .psstE2E && $0.fromNode == target }
            }
            check(got, "received + decrypted a psst E2E message from the peer")
        } else {
            out("SKIP  receiving a psst E2E message over the air — the second radio has no psst lab client (see LAB-LORA.md)")
        }
        return finish()
    }

    func finish() -> Int32 {
        out("result: \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        if let path = args["report"] {
            try? (report.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        client?.disconnect()
        return failures == 0 ? 0 : 1
    }
}

let code = await Tool(args: Args()).run()
exit(code)
