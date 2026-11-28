//
// PSST (L1c): psst lab — presents the LoRa section as a full-screen cover of the NavigationSplitCoordinator, i.e. at
// the top of the hierarchy, like Element's room directory search. Build 1 attached `.fullScreenCover` to HomeScreen
// (and the device scan `.sheet` to a List section): SwiftUI tears such presentations down on hierarchy changes
// (see NavigationSplitCoordinatorView — "otherwise sheets will be automatically dismissed on hierarchy changes"),
// which closed LoRa while scanning (Bluetooth permission / pairing alerts, constant re-renders from scan results).
//

import PsstLabUI
import SwiftUI

@MainActor
final class PsstLabLoRaRouter {
    static let shared = PsstLabLoRaRouter()
    private weak var navigationSplitCoordinator: NavigationSplitCoordinator?
    private weak var presented: PsstLabLoRaCoordinator?

    /// Called by ChatsTabFlowCoordinator, which owns the split coordinator of the chats tab.
    func register(_ coordinator: NavigationSplitCoordinator) {
        navigationSplitCoordinator = coordinator
    }

    func open(profile: UserProfile? = nil) {
        if let profile { Self.update(profile: profile) }
        guard let navigationSplitCoordinator else {
            MXLog.error("PSST lab: LoRa requested before the chats tab registered its split coordinator")
            return
        }
        guard presented == nil else { return } // already on screen
        let coordinator = PsstLabLoRaCoordinator { [weak self] in self?.close() }
        presented = coordinator
        navigationSplitCoordinator.setFullScreenCoverCoordinator(coordinator)
    }

    func close() {
        presented = nil
        navigationSplitCoordinator?.setFullScreenCoverCoordinator(nil)
    }

    /// Tells psst lab which psst user this phone is (used in the LoRa card).
    static func update(profile: UserProfile) {
        LabMeshModel.shared.matrixUserID = profile.id
        LabMeshModel.shared.displayName = profile.displayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(profile.id.dropFirst().prefix { $0 != ":" })
    }
}

final class PsstLabLoRaCoordinator: CoordinatorProtocol {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func toPresentable() -> AnyView {
        AnyView(LoRaRootView(model: .shared, onClose: onClose))
    }
}
