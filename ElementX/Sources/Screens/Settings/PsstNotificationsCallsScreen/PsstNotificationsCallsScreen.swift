//
// PSST: Settings → "Notifications & calls" / "Upozornenia a hovory".
//
// Every row is a toggle whose state and one-line description always come from the real system state
// (UNUserNotificationCenter settings, AVCaptureDevice authorization, CallKit availability). Turning a row on asks
// iOS for the permission when iOS allows that; otherwise it says in one sentence what to turn on and opens the
// app's page in iOS Settings. The state is read again whenever the app returns to the foreground.
// Two tests: a local notification through the same category and sound as messages, and a CallKit test call that
// rings for ~5 s (falls back to playing a sound inside the app when CallKit refuses).
// On the first launch of every app version the screen opens by itself when something required is missing,
// with the missing rows highlighted (PsstNotificationsCallsCheck, once per version).
//
// Strings: ElementX/Resources/Localizations/{en,sk}.lproj/Psst.strings (table "Psst").
//

import AVFoundation
import CallKit
import Combine
import SwiftUI
import UIKit
import UserNotifications

// MARK: - System state

nonisolated enum PsstPermissionItem: String, CaseIterable, Identifiable {
    case notifications
    case sound
    case lockScreen = "lock_screen"
    case banners
    case callKit = "callkit"
    case microphone
    case camera

    var id: String {
        rawValue
    }

    /// Missing required items open the screen automatically (once per version) and are highlighted.
    var isRequired: Bool {
        switch self {
        case .notifications, .sound, .lockScreen, .banners, .microphone: true
        case .callKit, .camera: false
        }
    }

    var isNotificationOption: Bool {
        switch self {
        case .sound, .lockScreen, .banners: true
        default: false
        }
    }

    var title: String {
        PsstL10n.tr("psst_nc_row_\(rawValue)")
    }

    /// One sentence saying what to turn on in iOS Settings.
    var settingsHint: String {
        PsstL10n.tr("psst_nc_hint_\(rawValue)")
    }

    var accessibilityIdentifier: String {
        "psst_nc-row-\(rawValue)"
    }
}

nonisolated struct PsstSystemState {
    var authorization: UNAuthorizationStatus = .notDetermined
    var sound: UNNotificationSetting = .notSupported
    var lockScreen: UNNotificationSetting = .notSupported
    var alert: UNNotificationSetting = .notSupported
    var alertStyle: UNAlertStyle = .none
    var microphone: AVAuthorizationStatus = .notDetermined
    var camera: AVAuthorizationStatus = .notDetermined
    /// Apple does not allow CallKit in mainland China; everywhere else it needs no permission.
    var callKitAvailable = true

    @MainActor
    static func read() async -> PsstSystemState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        var state = PsstSystemState()
        state.authorization = settings.authorizationStatus
        state.sound = settings.soundSetting
        state.lockScreen = settings.lockScreenSetting
        state.alert = settings.alertSetting
        state.alertStyle = settings.alertStyle
        state.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        state.camera = AVCaptureDevice.authorizationStatus(for: .video)
        state.callKitAvailable = Locale.current.region?.identifier != "CN"
        return state
    }

    var notificationsAllowed: Bool {
        authorization == .authorized || authorization == .ephemeral
    }

    func isOn(_ item: PsstPermissionItem) -> Bool {
        switch item {
        case .notifications: notificationsAllowed
        case .sound: notificationsAllowed && sound == .enabled
        case .lockScreen: notificationsAllowed && lockScreen == .enabled
        case .banners: notificationsAllowed && alert == .enabled && alertStyle != .none
        case .callKit: callKitAvailable
        case .microphone: microphone == .authorized
        case .camera: camera == .authorized
        }
    }

    var missingRequired: [PsstPermissionItem] {
        PsstPermissionItem.allCases.filter { $0.isRequired && !isOn($0) }
    }

    func description(_ item: PsstPermissionItem) -> String {
        switch item {
        case .notifications:
            switch authorization {
            case .authorized, .ephemeral: PsstL10n.tr("psst_nc_auth_authorized")
            case .provisional: PsstL10n.tr("psst_nc_auth_provisional")
            case .denied: PsstL10n.tr("psst_nc_auth_denied")
            case .notDetermined: PsstL10n.tr("psst_nc_auth_not_determined")
            @unknown default: PsstL10n.tr("psst_nc_auth_denied")
            }
        case .sound:
            notificationsAllowed ? PsstL10n.tr(sound == .enabled ? "psst_nc_sound_on" : "psst_nc_sound_off") : PsstL10n.tr("psst_nc_needs_notifications")
        case .lockScreen:
            notificationsAllowed ? PsstL10n.tr(lockScreen == .enabled ? "psst_nc_lock_on" : "psst_nc_lock_off") : PsstL10n.tr("psst_nc_needs_notifications")
        case .banners:
            if !notificationsAllowed {
                PsstL10n.tr("psst_nc_needs_notifications")
            } else if alert != .enabled || alertStyle == .none {
                PsstL10n.tr("psst_nc_banners_off")
            } else {
                PsstL10n.tr(alertStyle == .alert ? "psst_nc_banners_persistent" : "psst_nc_banners_temporary")
            }
        case .callKit:
            PsstL10n.tr(callKitAvailable ? "psst_nc_callkit_on" : "psst_nc_callkit_region")
        case .microphone:
            Self.describe(microphone)
        case .camera:
            Self.describe(camera)
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: PsstL10n.tr("psst_nc_av_authorized")
        case .denied: PsstL10n.tr("psst_nc_av_denied")
        case .restricted: PsstL10n.tr("psst_nc_av_restricted")
        case .notDetermined: PsstL10n.tr("psst_nc_av_not_determined")
        @unknown default: PsstL10n.tr("psst_nc_av_denied")
        }
    }
}

// MARK: - Automatic check (first launch of every version)

enum PsstNotificationsCallsCheck {
    private static let defaultsKey = "psst.notificationsCallsCheckedVersion"

    private static var currentVersion: String {
        "\(InfoPlistReader.main.bundleShortVersionString)-\(InfoPlistReader.main.bundleVersion)"
    }

    /// True at most once per app version: on its first check, when something required is missing.
    static func shouldPresentAutomatically() async -> Bool {
        if ProcessInfo.isRunningUnitTests || ProcessInfo.isRunningUITests || ProcessInfo.isRunningAccessibilityTests {
            return false
        }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: defaultsKey) != currentVersion else {
            return false
        }
        defaults.set(currentVersion, forKey: defaultsKey)
        let missing = await PsstSystemState.read().missingRequired
        MXLog.info("PSST notifications & calls check for \(currentVersion): missing \(missing.map(\.rawValue))")
        return !missing.isEmpty
    }
}

// MARK: - Ringing test

/// Reports a CallKit incoming test call on its own provider (so the app's call manager never sees it) and ends it
/// after `duration`. Falls back to playing the message sound in the app when CallKit refuses the call.
final class PsstRingtoneTester: NSObject, CXProviderDelegate {
    private var provider: CXProvider?
    private var callID: UUID?
    private var player: AVAudioPlayer?

    func ring(for duration: Duration, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        if let icon = UIImage(named: "images/app-logo") {
            configuration.iconTemplateImageData = icon.pngData()
        }
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)
        self.provider = provider

        let id = UUID()
        callID = id
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "psst")
        update.localizedCallerName = PsstL10n.tr("psst_nc_ringtone_caller")
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.provider = nil
                    completion(.failure(error))
                    return
                }
                try? await Task.sleep(for: duration)
                self.endCall()
                completion(.success(()))
            }
        }
    }

    func playFallback(for duration: Duration) {
        guard let url = Bundle.main.url(forResource: "message", withExtension: "caf") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.play()
            self.player = player
            Task { @MainActor in
                try? await Task.sleep(for: duration)
                self.player?.stop()
                self.player = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            MXLog.error("PSST ringing fallback failed: \(error)")
        }
    }

    private func endCall() {
        if let callID, let provider {
            provider.reportCall(with: callID, endedAt: nil, reason: .remoteEnded)
        }
        callID = nil
        provider?.invalidate()
        provider = nil
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        callID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Answering the test call just ends it.
        action.fulfill()
        endCall()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        callID = nil
    }
}

// MARK: - View model

final class PsstNotificationsCallsViewModel: ObservableObject {
    struct SettingsPrompt: Identifiable {
        let id = UUID()
        let message: String
        let url: URL
    }

    @Published private(set) var state = PsstSystemState()
    @Published private(set) var highlighted: Set<PsstPermissionItem> = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var callKitTestResult: String?
    @Published private(set) var isRinging = false
    @Published var settingsPrompt: SettingsPrompt?

    let showsDoneButton: Bool
    private let accountSettings: AccountSettings
    private let onDone: () -> Void
    private var queue: [PsstPermissionItem] = []
    private var isProcessingQueue = false
    private let ringtoneTester = PsstRingtoneTester()

    init(highlightMissing: Bool, accountSettings: AccountSettings, onDone: @escaping () -> Void) {
        showsDoneButton = highlightMissing
        self.accountSettings = accountSettings
        self.onDone = onDone
        Task {
            await refresh()
            if highlightMissing {
                highlighted = Set(state.missingRequired)
            }
        }
    }

    var anyRequiredMissing: Bool {
        !state.missingRequired.isEmpty
    }

    func refresh() async {
        let newState = await PsstSystemState.read()
        state = newState
        highlighted = highlighted.filter { !newState.isOn($0) }
    }

    func binding(for item: PsstPermissionItem) -> Binding<Bool> {
        Binding(get: { [weak self] in
            self?.state.isOn(item) ?? false
        }, set: { [weak self] isOn in
            guard let self else { return }
            if isOn {
                enqueue([item])
            } else if state.isOn(item) {
                // iOS never lets an app revoke its own permissions.
                settingsPrompt = .init(message: PsstL10n.tr("psst_nc_hint_turn_off"), url: Self.settingsURL(for: item))
            }
        })
    }

    func requestAllMissing() {
        enqueue(state.missingRequired)
    }

    func done() {
        onDone()
    }

    func openSettings(_ url: URL) {
        UIApplication.shared.open(url)
    }

    // MARK: Requests, one after another

    private func enqueue(_ items: [PsstPermissionItem]) {
        for item in items where !queue.contains(item) {
            queue.append(item)
        }
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        Task {
            while !queue.isEmpty {
                let item = queue.removeFirst()
                await refresh()
                guard !state.isOn(item) else { continue }
                if let prompt = await request(item) {
                    // Leaving for Settings: the rest waits until the user is back and taps again.
                    queue.removeAll()
                    settingsPrompt = prompt
                }
                await refresh()
            }
            isProcessingQueue = false
        }
    }

    /// Asks iOS for the permission; returns a Settings prompt when iOS only allows changing it there.
    private func request(_ item: PsstPermissionItem) async -> SettingsPrompt? {
        switch item {
        case .notifications, .sound, .lockScreen, .banners:
            if state.authorization == .notDetermined || state.authorization == .provisional {
                do {
                    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                } catch {
                    MXLog.error("PSST notification authorization failed: \(error)")
                }
                await refresh()
                if item == .notifications || state.isOn(item) || !state.notificationsAllowed {
                    return nil
                }
            }
            return .init(message: item.settingsHint, url: Self.settingsURL(for: item))
        case .microphone, .camera:
            let type: AVMediaType = item == .microphone ? .audio : .video
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: type)
                return nil
            }
            return .init(message: item.settingsHint, url: Self.settingsURL(for: item))
        case .callKit:
            return nil
        }
    }

    private static func settingsURL(for item: PsstPermissionItem) -> URL {
        let string = (item == .notifications || item.isNotificationOption) ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
        return URL(string: string) ?? URL(string: UIApplication.openSettingsURLString)!
    }

    // MARK: Tests

    func sendTestNotification() {
        Task {
            await refresh()
            if state.authorization == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refresh()
            }
            guard state.notificationsAllowed || state.authorization == .provisional else {
                statusMessage = PsstL10n.tr("psst_nc_test_notification_denied")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "psst"
            content.body = PsstL10n.tr("psst_nc_test_notification_body")
            // Same category and sound as a message notification built by the NSE.
            content.categoryIdentifier = NotificationConstants.Category.message
            let tone = accountSettings.selectedNotificationTone ?? accountSettings.defaultNotificationTone.publisher.value
            content.sound = UNNotificationSound(named: UNNotificationSoundName(NotificationToneManager.soundName(for: tone)))
            content.threadIdentifier = "psst-test"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(identifier: "psst-test-\(UUID().uuidString)", content: content, trigger: trigger)
            do {
                try await UNUserNotificationCenter.current().add(request)
                var message = PsstL10n.tr("psst_nc_test_notification_sent")
                if !state.isOn(.sound) {
                    message += " " + PsstL10n.tr("psst_nc_test_notification_silent")
                }
                statusMessage = message
            } catch {
                statusMessage = PsstL10n.tr("psst_nc_test_notification_failed", error.localizedDescription)
            }
        }
    }

    func testRingtone() {
        guard !isRinging else { return }
        isRinging = true
        statusMessage = PsstL10n.tr("psst_nc_ringtone_running")
        ringtoneTester.ring(for: .seconds(5)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                callKitTestResult = PsstL10n.tr("psst_nc_callkit_test_ok")
                statusMessage = PsstL10n.tr("psst_nc_ringtone_done")
                isRinging = false
            case .failure(let error):
                MXLog.error("PSST CallKit test call failed: \(error)")
                callKitTestResult = PsstL10n.tr("psst_nc_callkit_test_failed", error.localizedDescription)
                statusMessage = PsstL10n.tr("psst_nc_ringtone_fallback", error.localizedDescription)
                ringtoneTester.playFallback(for: .seconds(5))
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    self.isRinging = false
                }
            }
        }
    }
}

// MARK: - View

struct PsstNotificationsCallsScreen: View {
    @ObservedObject var viewModel: PsstNotificationsCallsViewModel

    var body: some View {
        Form {
            Section {
                if !viewModel.highlighted.isEmpty {
                    Label(PsstL10n.tr("psst_nc_missing_banner") + " " + PsstPermissionItem.allCases.filter { viewModel.highlighted.contains($0) }.map(\.title).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.compound.bodyMD)
                        .foregroundColor(.compound.textPrimary)
                        .listRowBackground(Color.orange.opacity(0.18))
                        .accessibilityIdentifier("psst_nc-missing_banner")
                }
                Text(PsstL10n.tr("psst_nc_intro"))
                    .font(.compound.bodySM)
                    .foregroundColor(.compound.textSecondary)
            }

            Section {
                row(.notifications)
                row(.sound)
                row(.lockScreen)
                row(.banners)
            } header: {
                Text(PsstL10n.tr("psst_nc_section_notifications"))
                    .compoundListSectionHeader()
            }

            Section {
                row(.callKit)
                row(.microphone)
                row(.camera)
            } header: {
                Text(PsstL10n.tr("psst_nc_section_calls"))
                    .compoundListSectionHeader()
            }

            Section {
                if viewModel.anyRequiredMissing {
                    Button(PsstL10n.tr("psst_nc_request_all")) {
                        viewModel.requestAllMissing()
                    }
                    .accessibilityIdentifier("psst_nc-request_all")
                }
                Button(PsstL10n.tr("psst_nc_test_notification")) {
                    viewModel.sendTestNotification()
                }
                .accessibilityIdentifier("psst_nc-test_notification")
                Button(PsstL10n.tr("psst_nc_test_ringtone")) {
                    viewModel.testRingtone()
                }
                .disabled(viewModel.isRinging)
                .accessibilityIdentifier("psst_nc-test_ringtone")
            } header: {
                Text(PsstL10n.tr("psst_nc_section_tests"))
                    .compoundListSectionHeader()
            } footer: {
                if let message = viewModel.statusMessage {
                    Text(message)
                        .compoundListSectionFooter()
                        .accessibilityIdentifier("psst_nc-status")
                }
            }
        }
        .compoundList()
        .navigationTitle(PsstL10n.tr("psst_nc_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone) {
                        viewModel.done()
                    }
                    .accessibilityIdentifier("psst_nc-done")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refresh() }
        }
        .alert(PsstL10n.tr("psst_nc_settings_title"),
               isPresented: Binding(get: { viewModel.settingsPrompt != nil },
                                    set: { if !$0 { viewModel.settingsPrompt = nil } }),
               presenting: viewModel.settingsPrompt) { prompt in
            Button(PsstL10n.tr("psst_nc_settings_open")) {
                viewModel.openSettings(prompt.url)
            }
            Button(L10n.actionCancel, role: .cancel) { }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private func row(_ item: PsstPermissionItem) -> some View {
        let isHighlighted = viewModel.highlighted.contains(item)
        var description = viewModel.state.description(item)
        if item == .callKit, let result = viewModel.callKitTestResult {
            description += " · " + result
        }
        return Toggle(isOn: viewModel.binding(for: item)) {
            HStack(alignment: .top, spacing: 8) {
                if isHighlighted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .accessibilityLabel(PsstL10n.tr("psst_nc_missing"))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.compound.bodyLG)
                        .foregroundColor(.compound.textPrimary)
                    Text(description)
                        .font(.compound.bodySM)
                        .foregroundColor(.compound.textSecondary)
                }
            }
        }
        // CallKit has no permission: the row only reports whether it is available.
        .disabled(item == .callKit)
        .listRowBackground(isHighlighted ? Color.orange.opacity(0.18) : nil)
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }
}

// MARK: - Coordinator

final class PsstNotificationsCallsScreenCoordinator: CoordinatorProtocol {
    private let viewModel: PsstNotificationsCallsViewModel

    init(highlightMissing: Bool, accountSettings: AccountSettings, onDone: @escaping () -> Void) {
        viewModel = PsstNotificationsCallsViewModel(highlightMissing: highlightMissing,
                                                    accountSettings: accountSettings,
                                                    onDone: onDone)
    }

    func toPresentable() -> AnyView {
        AnyView(PsstNotificationsCallsScreen(viewModel: viewModel))
    }
}
