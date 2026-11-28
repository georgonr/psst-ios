// PSST (L1): Meshtastic BLE protocol logic, independent of CoreBluetooth (unit-tested with a fake link).
// https://meshtastic.org/docs/development/device/client-api/ — service 6ba1b218-…; ToRadio (write), FromRadio (read,
// one FromRadio per read, empty value = queue drained), FromNum (notify: new packets waiting).
import Foundation
import PsstMesh

public enum MeshtasticBLE {
    public static let service = "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD"
    public static let toRadio = "F75C76D2-129E-4DAD-A1DD-7866124401E7"
    public static let fromRadio = "2C55E69E-4993-11ED-B878-0242AC120002"
    public static let fromNum = "ED9DA18C-A800-4F66-A670-AA7547E34453"
    public static let logRecord = "5A3D6E49-06E6-4423-9944-E9DE8CDF9547"
    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
}

/// What the session needs from a connected peripheral.
@MainActor
public protocol BLELink: AnyObject {
    func readFromRadio()
    func writeToRadio(_ data: Data)
    func subscribeFromNum()
}

/// Drives the read/write cycle. Rules: never more than one FromRadio read in flight; after every write and every
/// FromNum notification read FromRadio until it returns an empty value; writes are serialized (write-with-response).
@MainActor
public final class BLESession {
    public weak var link: BLELink?
    public var onFromRadio: ((Data) -> Void)?
    private(set) public var reading = false
    private var readAgain = false
    private var writeQueue: [Data] = []
    private var writing = false
    private(set) public var ready = false

    public init() {}

    /// All three characteristics found (and FromRadio is readable — i.e. pairing done).
    public func linkReady() {
        ready = true
        link?.subscribeFromNum()
        pumpWrites()
        drain()
    }

    public func reset() {
        ready = false; reading = false; readAgain = false; writing = false; writeQueue.removeAll()
    }

    public func send(_ toRadio: Data) {
        writeQueue.append(toRadio)
        pumpWrites()
    }

    private func pumpWrites() {
        guard ready, !writing, !writeQueue.isEmpty else { return }
        writing = true
        link?.writeToRadio(writeQueue.removeFirst())
    }

    /// Write-with-response completed.
    public func didWrite(error: Error?) {
        writing = false
        pumpWrites()
        drain()
    }

    public func didNotifyFromNum() { drain() }

    /// Value of a FromRadio read (empty = nothing more waiting).
    public func didRead(_ value: Data?, error: Error?) {
        reading = false
        if error == nil, let value, !value.isEmpty {
            onFromRadio?(value)
            drain()
        } else if readAgain {
            readAgain = false
            drain()
        }
    }

    public func drain() {
        guard ready else { return }
        if reading { readAgain = true; return }
        reading = true
        link?.readFromRadio()
    }
}
