//
// PSST (D96): screen protection for chats with `eu.macet.psst.screen_protection` = enabled.
//
// iOS doesn't let an app block screenshots or recordings (and psst uses no undocumented tricks such as a secure
// text field layer). Instead, while such a chat is open (including its details, threads and media, which are pushed
// on top of it):
// - a neutral psst screen covers the app while the screen is recorded, mirrored or shared
//   (`UITraitCollection.sceneCaptureState == .active`) and while the app is inactive or in the background, so the
//   app switcher snapshot doesn't show the chat;
// - a screenshot (`UIApplication.userDidTakeScreenshotNotification`) sends an `m.notice` to the chat with
//   `"eu.macet.psst.screenshot": true`, at most one per 10 s per chat.
// Specification: psst docs/psst-26.11.1-spec.md (section 2).
//

import Combine
import Compound
import MatrixRustSDK
import SwiftUI
import UIKit

/// One per open room screen (owned by `RoomScreenCoordinator`).
@MainActor
final class PsstRoomScreenProtectionSession {
    private static let screenshotNoticeInterval: TimeInterval = 10
    private static var lastScreenshotNotice: [String: Date] = [:]

    private let roomProxy: JoinedRoomProxyProtocol
    private let userSession: UserSessionProtocol
    private var cancellables = Set<AnyCancellable>()
    // periphery:ignore - kept alive for the SDK state subscriptions
    private var stateSubscriptions: [TaskHandle] = []
    private var isStopped = false

    init(roomProxy: JoinedRoomProxyProtocol, userSession: UserSessionProtocol) {
        self.roomProxy = roomProxy
        self.userSession = userSession

        PsstScreenShield.shared.roomOpened(roomProxy.id)

        if let room = roomProxy as? PsstRoomStateAccess {
            stateSubscriptions = PsstRoomSettingsStore.shared.subscribe(room)
            Task { await PsstRoomSettingsStore.shared.refresh(room) }
        }

        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenshotTaken() }
            .store(in: &cancellables)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        cancellables.removeAll()
        stateSubscriptions.removeAll()
        PsstScreenShield.shared.roomClosed(roomProxy.id)
    }

    private func screenshotTaken() {
        let roomID = roomProxy.id
        guard PsstRoomSettingsStore.shared.isScreenProtected(roomID),
              let room = roomProxy as? PsstRoomStateAccess else {
            return
        }

        let now = Date.now
        if let last = Self.lastScreenshotNotice[roomID], now.timeIntervalSince(last) < Self.screenshotNoticeInterval {
            return
        }
        Self.lastScreenshotNotice[roomID] = now

        let profile = userSession.clientProxy.userProfilePublisher.value
        let ownName = profile.displayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(roomProxy.ownUserID.dropFirst().prefix { $0 != ":" })
        let content: [String: Any] = ["msgtype": "m.notice",
                                      "body": PsstL10n.tr("psst_sp_screenshot_notice", ownName),
                                      PsstStateEventType.screenshotKey: true]
        let contentJSON = PsstStateContent.json(content)
        Task {
            _ = await room.psstSendMessageEvent(eventType: "m.room.message", contentJSON: contentJSON)
        }
    }
}

/// Covers the whole app with a neutral psst screen while a protected chat is open and the screen is captured or
/// the app isn't active.
@MainActor
final class PsstScreenShield {
    static let shared = PsstScreenShield()

    private var openRooms: [String: Int] = [:]
    private var isAppInactive = false
    private var window: UIWindow?
    private var cancellables = Set<AnyCancellable>()
    private var pollCancellable: AnyCancellable?

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.setInactive(true) }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setInactive(true) }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setInactive(false) }
            .store(in: &cancellables)
        center.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        center.publisher(for: PsstRoomSettingsStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    func roomOpened(_ roomID: String) {
        openRooms[roomID, default: 0] += 1
        update()
    }

    func roomClosed(_ roomID: String) {
        guard let count = openRooms[roomID] else { return }
        openRooms[roomID] = count > 1 ? count - 1 : nil
        update()
    }

    // MARK: - Private

    private var isAnyOpenRoomProtected: Bool {
        openRooms.keys.contains { PsstRoomSettingsStore.shared.isScreenProtected($0) }
    }

    private var windowScenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    private var isScreenCaptured: Bool {
        windowScenes.contains { $0.traitCollection.sceneCaptureState == .active }
    }

    private func setInactive(_ inactive: Bool) {
        isAppInactive = inactive
        update()
    }

    private func update() {
        let isProtected = isAnyOpenRoomProtected

        // Capture can start from Control Center while the app stays active and the trait change isn't announced
        // through a notification, so poll cheaply while a protected chat is open.
        if isProtected, pollCancellable == nil {
            pollCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.updateCover() }
        } else if !isProtected {
            pollCancellable = nil
        }

        updateCover()
    }

    private func updateCover() {
        let shouldCover = isAnyOpenRoomProtected && (isAppInactive || isScreenCaptured)

        if shouldCover {
            let window = window ?? makeWindow()
            window?.isHidden = false
        } else {
            window?.isHidden = true
        }
    }

    private func makeWindow() -> UIWindow? {
        guard let scene = windowScenes.first(where: { $0.activationState == .foregroundActive })
            ?? windowScenes.first(where: { $0.activationState == .foregroundInactive })
            ?? windowScenes.first else {
            return nil
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        let hostingController = UIHostingController(rootView: PsstShieldView())
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.accessibilityViewIsModal = true
        self.window = window
        return window
    }
}

private struct PsstShieldView: View {
    var body: some View {
        ZStack {
            Color.compound.bgCanvasDefault
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(asset: Asset.Images.appLogo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text(PsstL10n.tr("psst_sp_shield"))
                    .font(.compound.bodyMD)
                    .foregroundColor(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}
