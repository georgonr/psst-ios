// PSST (L1c): regression test for "the LoRa screen closes while scanning" (TestFlight build 1).
// A simulated scanner adds radios one by one and keeps re-advertising them with jittering RSSI (as CoreBluetooth does
// with AllowDuplicates). The list the scan screen shows must not reorder rows that are already visible (rows jumping
// under the finger, every advertisement re-rendering the whole LoRa hierarchy) and must be published at most a few
// times per second.
import Foundation
@testable import PsstLabUI
@testable import PsstMeshBLE
import Testing

@Suite @MainActor struct ScanListTests {
    @Test func simulatedScannerKeepsRowsStableAndThrottlesUpdates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("psstlab-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = LabMeshModel(directory: dir)
        var publishes = 0
        let sub = model.$radios.dropFirst().sink { _ in publishes += 1 }
        defer { sub.cancel() }

        let ids = (0..<4).map { _ in UUID() }
        let start = Date()
        var orders: [[UUID]] = []
        // 3 s of advertising: a new radio every 0.5 s, each radio re-advertises every 50 ms with ±10 dB jitter
        for tick in 0..<60 {
            let now = start.addingTimeInterval(Double(tick) * 0.05)
            let visible = min(ids.count, tick / 10 + 1)
            for i in 0..<visible {
                model.transport.ingestAdvertisement(id: ids[i], name: "Meshtastic_\(i)", rssi: -60 - Int.random(in: 0...10) - i, now: now)
            }
            model.flushRadios(now: now)
            orders.append(model.radios.map(\.id))
        }
        model.flushRadios(now: start.addingTimeInterval(10))
        #expect(Set(model.radios.map(\.id)) == Set(ids))
        // already visible rows never change their position
        for (a, b) in zip(orders, orders.dropFirst()) {
            #expect(Array(b.prefix(a.count)) == a, "rows reordered while scanning: \(a) → \(b)")
        }
        // ≤ 2 updates per second of simulated time (+ the final flush), not one per advertisement (~150)
        #expect(publishes <= 8, "radios published \(publishes)× in 3 s")
    }
}
