//
// PSST (L1): psst lab only — „Prepojiť s LoRa“ in the details of a direct chat. Sends this phone's LoRa card
// (X25519 public key + LoRa node + Matrix user) as an end-to-end encrypted message into the chat; the other psst lab
// app picks it up from the timeline (PsstLabMatrixBridge) and links the contact. See DECISIONS.md L1-xx, LAB-LORA.md.
//

import Compound
import PsstLabUI
import PsstMesh
import SwiftUI

@MainActor
final class PsstLabLoRaLinkModel: ObservableObject {
    @Published private(set) var isSending = false
    @Published var message: String?

    private let roomProxy: JoinedRoomProxyProtocol
    let lab = LabMeshModel.shared

    init(roomProxy: JoinedRoomProxyProtocol) {
        self.roomProxy = roomProxy
    }

    func status(for userID: String) -> String {
        var parts: [String] = []
        if let peer = lab.peer(matrixUserID: userID) {
            parts.append(psstTr("lora_dm_linked", MeshNode.userID(peer.card.nodeNum), LabIdentity.fingerprint(peer.card.publicKey)))
        } else {
            parts.append(psstTr("lora_dm_waiting"))
        }
        if let sent = lab.cardSent(to: userID) {
            parts.append(psstTr("lora_dm_sent_at", sent.formatted(date: .abbreviated, time: .shortened)))
        }
        return parts.joined(separator: " ")
    }

    func sendCard(to userID: String) {
        guard let body = lab.linkMessageBody(), let card = lab.myCard() else {
            message = psstTr("lora_dm_connect_first")
            return
        }
        guard let room = roomProxy as? PsstRoomStateAccess else { return }
        let content: [String: Any] = ["msgtype": "m.text",
                                      "body": body,
                                      "eu.macet.psst.lab.lora_card": card.encoded]
        let json = PsstStateContent.json(content)
        isSending = true
        Task {
            defer { isSending = false }
            switch await room.psstSendMessageEvent(eventType: "m.room.message", contentJSON: json) {
            case .success:
                lab.markCardSent(to: userID)
                message = psstTr("lora_dm_card_sent")
            case .failure:
                message = psstTr("lora_dm_card_failed")
            }
        }
    }
}

struct PsstLabLoRaSection: View {
    @ObservedObject var model: PsstLabLoRaLinkModel
    let recipientID: String

    var body: some View {
        Section {
            ListRow(label: .default(title: psstTr("lora_dm_link"), icon: \.key),
                    details: model.isSending ? .isWaiting(true) : nil,
                    kind: .button { model.sendCard(to: recipientID) })
                .disabled(model.isSending)
            ListRow(label: .default(title: psstTr("lora_dm_open"), icon: \.chat),
                    kind: .button { PsstLabLoRaRouter.shared.open() })
        } header: {
            Text("\(psstAppName) · LoRa")
                .compoundListSectionHeader()
        } footer: {
            Text(psstTr("lora_dm_footer", model.status(for: recipientID)))
                .compoundListSectionFooter()
        }
        .alert("LoRa", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
               actions: { Button(L10n.actionOk) { model.message = nil } },
               message: { Text(model.message ?? "") })
    }
}

/// Timeline hook: every text / notice message body is offered to psst lab, which links a contact when the body
/// carries a LoRa card from its own sender. Cheap check first — the factory runs for every timeline item.
nonisolated enum PsstLabMatrixBridge {
    static func observe(body: String, sender: String, isOutgoing: Bool, timestamp: Date) {
        guard !isOutgoing, body.contains(PeerCard.prefix) else { return }
        Task { @MainActor in
            LabMeshModel.shared.receivedMatrixMessage(body: body, sender: sender, isOwn: isOutgoing, timestamp: timestamp)
        }
    }
}
