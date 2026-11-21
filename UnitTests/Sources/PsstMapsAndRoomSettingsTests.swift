//
// PSST (D95, D97): psst map URLs and disappearing message helpers.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct PsstMapsAndRoomSettingsTests {
    private let psstMaps = MapTilerConfiguration(baseURL: "https://app.psst.pro/maps/styles",
                                                 apiKey: "",
                                                 lightStyleID: "liberty",
                                                 darkStyleID: "dark")
    
    @Test
    func psstMapsStyleURLs() {
        #expect(psstMaps.isEnabled)
        #expect(psstMaps.interactiveMapURL(for: .light) == URL(string: "https://app.psst.pro/maps/styles/liberty"))
        #expect(psstMaps.interactiveMapURL(for: .dark) == URL(string: "https://app.psst.pro/maps/styles/dark"))
        #expect(psstMaps.staticMapTileImageURL(for: .light,
                                               coordinates: .init(latitude: 48.1, longitude: 17.1),
                                               zoomLevel: 15,
                                               size: .init(width: 300, height: 200),
                                               attribution: .bottomLeft) == nil)
    }
    
    @Test
    func retentionOptions() {
        #expect(PsstRetentionOption(maxLifetime: 300_000) == .fiveMinutes)
        #expect(PsstRetentionOption(maxLifetime: 604_800_000) == .oneWeek)
        #expect(PsstRetentionOption(maxLifetime: nil) == .off)
        #expect(PsstRetentionOption(maxLifetime: 1234) == nil)
        #expect(PsstStateContent.maxLifetime(in: ["max_lifetime": 3_600_000]) == 3_600_000)
        #expect(PsstStateContent.maxLifetime(in: [:]) == nil)
        #expect(PsstStateContent.screenProtectionEnabled(in: ["enabled": true]))
        #expect(!PsstStateContent.screenProtectionEnabled(in: [:]))
    }
    
    @Test
    func psstStateEventTypes() {
        // The Rust SDK reports m.room.retention under its unstable MSC1763 name in the timeline.
        #expect(PsstStateEventStrings.isPsstStateEvent("m.room.retention"))
        #expect(PsstStateEventStrings.isPsstStateEvent("org.matrix.msc1763.retention"))
        #expect(PsstStateEventStrings.isPsstStateEvent("eu.macet.psst.screen_protection"))
        #expect(!PsstStateEventStrings.isPsstStateEvent("com.example.other"))
        let json = #"{"type":"org.matrix.msc1763.retention","content":{"max_lifetime":300000},"origin_server_ts":1}"#
        #expect(PsstStateEventStrings.text(eventType: "org.matrix.msc1763.retention", eventJSON: json, senderDisplayName: "Jana") != nil)
    }
}
