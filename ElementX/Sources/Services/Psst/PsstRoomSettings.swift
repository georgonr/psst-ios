//
// PSST (D95, D96): per-room psst settings carried in room state.
//
// - `m.room.retention` (MSC1763), state key "", content `{"max_lifetime": <ms>}`; off = `{}`.
//   The psst server (Synapse) purges expired events itself; the apps additionally stop showing message events
//   whose `origin_server_ts + max_lifetime` lies in the past (also offline, re-checked at least every 30 s).
// - `eu.macet.psst.screen_protection`, state key "", content `{"enabled": true|false}`.
//
// The values are kept per room in `PsstRoomSettingsStore` (persisted in UserDefaults so that expired messages stay
// hidden without a connection). They are updated from the local SDK state store, a direct
// `GET /rooms/{roomId}/state/{type}` (the sliding sync doesn't request these custom types as required state), state
// subscriptions and state events seen in the timeline. Specification: psst docs/psst-26.11.1-spec.md.
//

import Foundation
import MatrixRustSDK
import Synchronization

nonisolated enum PsstStateEventType {
    static let retention = "m.room.retention"
    static let screenProtection = "eu.macet.psst.screen_protection"
    /// Key added to the screenshot notice (`m.notice`) sent when someone takes a screenshot of a protected chat.
    static let screenshotKey = "eu.macet.psst.screenshot"
}

/// The disappearing message choices offered in room details (milliseconds).
nonisolated enum PsstRetentionOption: Hashable, CaseIterable {
    case off
    case fiveMinutes
    case oneHour
    case oneDay
    case oneWeek

    var maxLifetime: UInt64? {
        switch self {
        case .off: nil
        case .fiveMinutes: 300_000
        case .oneHour: 3_600_000
        case .oneDay: 86_400_000
        case .oneWeek: 604_800_000
        }
    }

    var title: String {
        switch self {
        case .off: PsstL10n.tr("psst_dm_off")
        case .fiveMinutes: PsstL10n.tr("psst_dm_5_minutes")
        case .oneHour: PsstL10n.tr("psst_dm_1_hour")
        case .oneDay: PsstL10n.tr("psst_dm_1_day")
        case .oneWeek: PsstL10n.tr("psst_dm_1_week")
        }
    }

    init?(maxLifetime: UInt64?) {
        guard let option = Self.allCases.first(where: { $0.maxLifetime == maxLifetime }) else { return nil }
        self = option
    }

    /// A label for any lifetime: one of the options, otherwise a rounded duration (set by another client).
    static func label(forMaxLifetime maxLifetime: UInt64) -> String {
        if let option = PsstRetentionOption(maxLifetime: maxLifetime) {
            return option.title
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
        let seconds = TimeInterval(maxLifetime) / 1000
        return formatter.string(from: seconds) ?? "\(Int(seconds)) s"
    }
}

nonisolated struct PsstRoomSettings: Equatable, Codable {
    /// `max_lifetime` of `m.room.retention` in milliseconds, nil when off.
    var maxLifetime: UInt64?
    var screenProtection = false
    /// Timestamps (ms) of the state events the values come from, so that an older event can't override a newer one.
    var retentionTimestamp: UInt64 = 0
    var screenProtectionTimestamp: UInt64 = 0
}

/// Parsing of the two state contents.
nonisolated enum PsstStateContent {
    static func object(fromJSON json: String?) -> [String: Any]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The `max_lifetime` of a retention content, nil when off/invalid.
    static func maxLifetime(in content: [String: Any]) -> UInt64? {
        let raw = content["max_lifetime"]
        let value: Double? = if let number = raw as? NSNumber {
            number.doubleValue
        } else if let string = raw as? String {
            Double(string)
        } else {
            nil
        }
        guard let value, value > 0 else { return nil }
        return UInt64(value)
    }

    static func screenProtectionEnabled(in content: [String: Any]) -> Bool {
        (content["enabled"] as? Bool) ?? ((content["enabled"] as? NSNumber)?.boolValue ?? false)
    }

    /// Splits a full event JSON (as found in the timeline debug info) into its content and timestamp.
    static func contentAndTimestamp(fromEventJSON json: String?) -> (content: [String: Any], timestamp: UInt64)? {
        guard let event = object(fromJSON: json) else { return nil }
        let content = (event["content"] as? [String: Any]) ?? [:]
        let timestamp = (event["origin_server_ts"] as? NSNumber)?.uint64Value ?? 0
        return (content, timestamp)
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Thread-safe store of the psst room settings, persisted in UserDefaults.
nonisolated final class PsstRoomSettingsStore: Sendable {
    static let shared = PsstRoomSettingsStore()

    /// Posted (on the thread of the change) with the room ID as `object` whenever a room's settings change.
    static let didChangeNotification = Notification.Name("PsstRoomSettingsStoreDidChange")

    private static let defaultsKey = "psstRoomSettings"

    private let settings: Mutex<[String: PsstRoomSettings]>

    private init() {
        var initial: [String: PsstRoomSettings] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: PsstRoomSettings].self, from: data) {
            initial = decoded
        }
        settings = Mutex(initial)
    }

    func settings(for roomID: String) -> PsstRoomSettings {
        settings.withLock { $0[roomID] } ?? PsstRoomSettings()
    }

    func maxLifetime(for roomID: String) -> UInt64? {
        settings(for: roomID).maxLifetime
    }

    func isScreenProtected(_ roomID: String) -> Bool {
        settings(for: roomID).screenProtection
    }

    /// Applies a state event content. `timestamp` 0 means "current state" (e.g. from a direct state fetch) which
    /// always wins over what is known; otherwise only newer events are applied.
    func apply(roomID: String, eventType: String, content: [String: Any], timestamp: UInt64) {
        let changed = settings.withLock { all -> Bool in
            var room = all[roomID] ?? PsstRoomSettings()
            let old = room
            switch eventType {
            case PsstStateEventType.retention:
                guard timestamp == 0 || timestamp >= room.retentionTimestamp else { return false }
                room.maxLifetime = PsstStateContent.maxLifetime(in: content)
                if timestamp != 0 { room.retentionTimestamp = timestamp }
            case PsstStateEventType.screenProtection:
                guard timestamp == 0 || timestamp >= room.screenProtectionTimestamp else { return false }
                room.screenProtection = PsstStateContent.screenProtectionEnabled(in: content)
                if timestamp != 0 { room.screenProtectionTimestamp = timestamp }
            default:
                return false
            }
            guard room != old else { return false }
            all[roomID] = room
            return true
        }

        guard changed else { return }
        persist()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: roomID)
    }

    private func persist() {
        let snapshot = settings.withLock { $0 }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Room access

/// What psst needs from a joined room (implemented by `JoinedRoomProxy`, which owns the SDK room).
protocol PsstRoomStateAccess: AnyObject {
    var id: String { get }
    var ownUserID: String { get }

    /// The contents (JSON) and timestamps of the state events of the given type in the local SDK store.
    func psstLocalStateEvents(eventType: String) async -> [(contentJSON: String, timestamp: UInt64)]
    /// Calls `onUpdate` with the content JSON and timestamp whenever the local state of that type changes.
    func psstSubscribeToStateEvents(eventType: String, onUpdate: @escaping @Sendable (String, UInt64) -> Void) -> TaskHandle?
    func psstSendStateEvent(eventType: String, contentJSON: String) async -> Result<Void, RoomProxyError>
    func psstSendMessageEvent(eventType: String, contentJSON: String) async -> Result<Void, RoomProxyError>
}

/// Direct reads of the current room state over the client-server API, keyed by account.
nonisolated final class PsstStateFetcher: Sendable {
    static let shared = PsstStateFetcher()

    typealias SessionProvider = @Sendable () -> (homeserverURL: String, accessToken: String)?

    private let providers = Mutex<[String: SessionProvider]>([:])

    func register(userID: String, provider: @escaping SessionProvider) {
        providers.withLock { $0[userID] = provider }
    }

    enum FetchResult: Sendable {
        /// The state content as JSON.
        case content(String)
        /// The room has no such state (M_NOT_FOUND).
        case notSet
        case failed
    }

    func fetch(userID: String, roomID: String, eventType: String) async -> FetchResult {
        guard let provider = providers.withLock({ $0[userID] }), let session = provider(),
              var components = URLComponents(string: session.homeserverURL) else {
            return .failed
        }

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let roomPath = roomID.addingPercentEncoding(withAllowedCharacters: allowed) ?? roomID
        let typePath = eventType.addingPercentEncoding(withAllowedCharacters: allowed) ?? eventType
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/_matrix/client/v3/rooms/\(roomPath)/state/\(typePath)/"
        guard let url = components.url else { return .failed }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                return .content(String(data: data, encoding: .utf8) ?? "{}")
            case 404:
                return .notSet
            default:
                MXLog.warning("PSST: state fetch \(eventType) failed with HTTP \(status)")
                return .failed
            }
        } catch {
            MXLog.warning("PSST: state fetch \(eventType) failed: \(error)")
            return .failed
        }
    }
}

extension PsstRoomSettingsStore {
    /// Reads both psst state types for a room (local store first, then the server) and applies them.
    @MainActor
    func refresh(_ room: PsstRoomStateAccess) async {
        let roomID = room.id
        let userID = room.ownUserID
        for eventType in [PsstStateEventType.retention, PsstStateEventType.screenProtection] {
            for event in await room.psstLocalStateEvents(eventType: eventType) {
                apply(roomID: roomID, eventType: eventType,
                      content: PsstStateContent.object(fromJSON: event.contentJSON) ?? [:],
                      timestamp: event.timestamp)
            }

            switch await PsstStateFetcher.shared.fetch(userID: userID, roomID: roomID, eventType: eventType) {
            case .content(let contentJSON):
                apply(roomID: roomID, eventType: eventType, content: PsstStateContent.object(fromJSON: contentJSON) ?? [:], timestamp: 0)
            case .notSet:
                apply(roomID: roomID, eventType: eventType, content: [:], timestamp: 0)
            case .failed:
                break // Offline or token refresh pending: keep what is known.
            }
        }
    }

    /// Subscribes to local state changes of both types. Keep the returned handles for as long as needed.
    @MainActor
    func subscribe(_ room: PsstRoomStateAccess) -> [TaskHandle] {
        let roomID = room.id
        return [PsstStateEventType.retention, PsstStateEventType.screenProtection].compactMap { eventType in
            room.psstSubscribeToStateEvents(eventType: eventType) { [weak self] contentJSON, timestamp in
                self?.apply(roomID: roomID, eventType: eventType,
                            content: PsstStateContent.object(fromJSON: contentJSON) ?? [:],
                            timestamp: timestamp)
            }
        }
    }
}

// MARK: - Disappearing messages

nonisolated enum PsstDisappearingMessages {
    /// Whether a timeline item is a message (not a state event or virtual item) that has outlived the room's
    /// `max_lifetime` and must no longer be shown.
    static func isExpired(_ item: RoomTimelineItemProtocol, maxLifetime: UInt64?, now: Date = .now) -> Bool {
        guard let maxLifetime,
              let eventItem = item as? EventBasedTimelineItemProtocol,
              !(eventItem is StateRoomTimelineItem) else {
            return false
        }
        return eventItem.timestamp.addingTimeInterval(TimeInterval(maxLifetime) / 1000) < now
    }
}

// MARK: - Timeline texts

nonisolated enum PsstStateEventStrings {
    static func isPsstStateEvent(_ eventType: String) -> Bool {
        eventType == PsstStateEventType.retention || eventType == PsstStateEventType.screenProtection
    }

    /// The timeline text for a psst state event, given the full event JSON.
    static func text(eventType: String, eventJSON: String?, senderDisplayName: String) -> String? {
        guard let content = PsstStateContent.contentAndTimestamp(fromEventJSON: eventJSON)?.content else {
            return nil
        }

        switch eventType {
        case PsstStateEventType.retention:
            if let maxLifetime = PsstStateContent.maxLifetime(in: content) {
                return PsstL10n.tr("psst_dm_state_on", senderDisplayName, PsstRetentionOption.label(forMaxLifetime: maxLifetime))
            }
            return PsstL10n.tr("psst_dm_state_off", senderDisplayName)
        case PsstStateEventType.screenProtection:
            return PsstL10n.tr(PsstStateContent.screenProtectionEnabled(in: content) ? "psst_sp_state_on" : "psst_sp_state_off",
                               senderDisplayName)
        default:
            return nil
        }
    }
}
