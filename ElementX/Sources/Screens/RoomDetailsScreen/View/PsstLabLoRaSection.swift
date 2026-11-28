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
            parts.append("Prepojené: uzol \(MeshNode.userID(peer.card.nodeNum)), kľúč \(LabIdentity.fingerprint(peer.card.publicKey)).")
        } else {
            parts.append("Kontakt zatiaľ neposlal svoju LoRa kartu (musí mať psst lab a stlačiť to isté tlačidlo).")
        }
        if let sent = lab.cardSent(to: userID) {
            parts.append("Vaša karta odoslaná \(sent.formatted(date: .abbreviated, time: .shortened)).")
        }
        return parts.joined(separator: " ")
    }

    func sendCard(to userID: String) {
        guard let body = lab.linkMessageBody(), let card = lab.myCard() else {
            message = "Najprv pripojte svoje LoRa rádio (LoRa → Vyhľadať zariadenia). Karta obsahuje číslo vášho LoRa uzla."
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
                message = "Karta odoslaná do šifrovaného rozhovoru. Keď kontakt v psst lab urobí to isté, budete prepojení."
            case .failure:
                message = "Kartu sa nepodarilo odoslať (bez internetu?)."
            }
        }
    }
}

struct PsstLabLoRaSection: View {
    @ObservedObject var model: PsstLabLoRaLinkModel
    let recipientID: String

    var body: some View {
        Section {
            ListRow(label: .default(title: "Prepojiť s LoRa", icon: \.key),
                    details: model.isSending ? .isWaiting(true) : nil,
                    kind: .button { model.sendCard(to: recipientID) })
                .disabled(model.isSending)
            ListRow(label: .default(title: "Otvoriť LoRa", icon: \.chat),
                    kind: .button { PsstLabLoRaRouter.shared.open() })
        } header: {
            Text("psst lab · LoRa")
                .compoundListSectionHeader()
        } footer: {
            Text("Pošle do tohto šifrovaného rozhovoru váš verejný kľúč a číslo LoRa uzla. Potom si môžete písať cez LoRa aj bez internetu, šifrované tak, že správu prečíta len tento kontakt. \(model.status(for: recipientID))")
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
