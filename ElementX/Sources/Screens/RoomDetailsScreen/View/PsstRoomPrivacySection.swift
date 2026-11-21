//
// PSST (D95, D96): "Disappearing messages" and "Screen protection" in room details (DM and group).
// Both are room state (`m.room.retention`, `eu.macet.psst.screen_protection`); a member who may not send that state
// sees the current value read-only. See PsstRoomSettings.swift and psst docs/psst-26.11.1-spec.md.
//

import Combine
import Compound
import MatrixRustSDK
import SwiftUI

@MainActor
final class PsstRoomPrivacySettingsModel: ObservableObject {
    /// `max_lifetime` in ms, 0 = off.
    @Published private(set) var maxLifetime: UInt64 = 0
    @Published private(set) var screenProtection = false
    @Published private(set) var canEditRetention = false
    @Published private(set) var canEditScreenProtection = false
    @Published private(set) var isSending = false
    @Published var errorMessage: String?

    private let roomProxy: JoinedRoomProxyProtocol
    private var cancellables = Set<AnyCancellable>()
    // periphery:ignore - kept alive for the SDK state subscriptions
    private var stateSubscriptions: [TaskHandle] = []

    init(roomProxy: JoinedRoomProxyProtocol) {
        self.roomProxy = roomProxy
        let roomID = roomProxy.id

        loadFromStore()
        updatePermissions(roomProxy.infoPublisher.value)

        NotificationCenter.default.publisher(for: PsstRoomSettingsStore.didChangeNotification)
            .filter { ($0.object as? String) == roomID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadFromStore() }
            .store(in: &cancellables)

        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in self?.updatePermissions(info) }
            .store(in: &cancellables)

        if let room = roomProxy as? PsstRoomStateAccess {
            stateSubscriptions = PsstRoomSettingsStore.shared.subscribe(room)
            Task { await PsstRoomSettingsStore.shared.refresh(room) }
        }
    }

    /// The picker entries: the psst choices, plus the current value when another client set a different one.
    var retentionItems: [(title: String, tag: UInt64)] {
        var items = PsstRetentionOption.allCases.map { (title: $0.title, tag: $0.maxLifetime ?? 0) }
        if maxLifetime != 0, PsstRetentionOption(maxLifetime: maxLifetime) == nil {
            items.append((title: PsstRetentionOption.label(forMaxLifetime: maxLifetime), tag: maxLifetime))
        }
        return items
    }

    var retentionLabel: String {
        maxLifetime == 0 ? PsstRetentionOption.off.title : PsstRetentionOption.label(forMaxLifetime: maxLifetime)
    }

    func setMaxLifetime(_ newValue: UInt64) {
        guard newValue != maxLifetime, canEditRetention else { return }
        let content: [String: Any] = newValue == 0 ? [:] : ["max_lifetime": newValue]
        send(eventType: PsstStateEventType.retention, content: content)
    }

    func setScreenProtection(_ enabled: Bool) {
        guard enabled != screenProtection, canEditScreenProtection else { return }
        send(eventType: PsstStateEventType.screenProtection, content: ["enabled": enabled])
    }

    // MARK: - Private

    private func loadFromStore() {
        let settings = PsstRoomSettingsStore.shared.settings(for: roomProxy.id)
        maxLifetime = settings.maxLifetime ?? 0
        screenProtection = settings.screenProtection
    }

    private func updatePermissions(_ info: RoomInfoProxyProtocol) {
        let canSend = roomProxy is PsstRoomStateAccess
        canEditRetention = canSend && (info.powerLevels?.canOwnUser(sendStateEvent: stateEventTypeFromString(s: PsstStateEventType.retention)) ?? false)
        canEditScreenProtection = canSend && (info.powerLevels?.canOwnUser(sendStateEvent: stateEventTypeFromString(s: PsstStateEventType.screenProtection)) ?? false)
    }

    private func send(eventType: String, content: [String: Any]) {
        guard let room = roomProxy as? PsstRoomStateAccess else { return }
        let roomID = roomProxy.id
        let contentJSON = PsstStateContent.json(content)
        isSending = true

        Task {
            defer { isSending = false }
            switch await room.psstSendStateEvent(eventType: eventType, contentJSON: contentJSON) {
            case .success:
                // Applied right away (also hides expired messages at once); the synced event confirms it.
                PsstRoomSettingsStore.shared.apply(roomID: roomID, eventType: eventType,
                                                   content: PsstStateContent.object(fromJSON: contentJSON) ?? [:],
                                                   timestamp: 0)
            case .failure:
                errorMessage = L10n.errorUnknown
                loadFromStore()
            }
        }
    }
}

struct PsstRoomPrivacySection: View {
    @ObservedObject var model: PsstRoomPrivacySettingsModel

    var body: some View {
        Section {
            if model.canEditRetention {
                ListRow(label: .default(title: PsstL10n.tr("psst_dm_title"), icon: \.history),
                        details: model.isSending ? .isWaiting(true) : nil,
                        kind: .picker(selection: Binding(get: { model.maxLifetime },
                                                         set: { model.setMaxLifetime($0) }),
                                      items: model.retentionItems))
                    .disabled(model.isSending)
            } else {
                ListRow(label: .default(title: PsstL10n.tr("psst_dm_title"), icon: \.history),
                        details: .title(model.retentionLabel),
                        kind: .label)
            }
        } footer: {
            Text(PsstL10n.tr("psst_dm_explanation"))
                .compoundListSectionFooter()
        }

        Section {
            if model.canEditScreenProtection {
                ListRow(label: .default(title: PsstL10n.tr("psst_sp_title"), icon: \.visibilityOff),
                        details: model.isSending ? .isWaiting(true) : nil,
                        kind: .toggle(Binding(get: { model.screenProtection },
                                              set: { model.setScreenProtection($0) })))
                    .disabled(model.isSending)
            } else {
                ListRow(label: .default(title: PsstL10n.tr("psst_sp_title"), icon: \.visibilityOff),
                        details: .title(model.screenProtection ? PsstL10n.tr("psst_on") : PsstL10n.tr("psst_dm_off")),
                        kind: .label)
            }
        } footer: {
            Text(PsstL10n.tr("psst_sp_explanation"))
                .compoundListSectionFooter()
        }
        .alert(PsstL10n.tr("psst_sp_title"),
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
               actions: { Button(L10n.actionOk) { model.errorMessage = nil } },
               message: { Text(model.errorMessage ?? "") })
    }
}
