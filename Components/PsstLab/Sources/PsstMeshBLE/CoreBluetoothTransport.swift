// PSST (L1): CoreBluetooth transport for the Meshtastic BLE API (iPhone; also compiles on macOS).
// Pairing: Meshtastic radios require an encrypted (bonded) link; iOS shows the system PIN dialog on the first read of
// FromRadio (PIN on the radio's screen, or the fixed PIN configured on the radio — often 123456).
@preconcurrency import CoreBluetooth
import Foundation
import PsstMesh

public struct DiscoveredRadio: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public var lastSeen: Date
}

@MainActor
public final class CoreBluetoothTransport: NSObject, MeshTransport, BLELink {
    public var onFromRadio: ((Data) -> Void)? {
        get { session.onFromRadio }
        set { session.onFromRadio = newValue }
    }
    public var onStateChange: ((TransportState) -> Void)?
    public var onDiscovered: (([DiscoveredRadio]) -> Void)?
    public var onBluetoothState: ((String?) -> Void)?   // nil = powered on, otherwise a Slovak explanation
    public var onBattery: ((Int) -> Void)?
    public var onRSSI: ((Int) -> Void)?

    public private(set) var discovered: [UUID: DiscoveredRadio] = [:]
    public var targetID: UUID?

    private let session = BLESession()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var fromNum: CBCharacteristic?
    private var wantScan = false
    private var wantConnect = false
    private var rssiTimer: Timer?
    private var readErrors = 0

    public override init() {
        super.init()
        session.link = self
    }

    private func ensureCentral() {
        // created lazily: creating CBCentralManager triggers the Bluetooth permission prompt (only when the user opens LoRa)
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    // MARK: Scanning

    public func startScan() {
        wantScan = true
        ensureCentral()
        if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: [CBUUID(string: MeshtasticBLE.service)],
                                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func stopScan() {
        wantScan = false
        central?.stopScan()
    }

    // MARK: MeshTransport

    public func start() {
        wantConnect = true
        ensureCentral()
        onStateChange?(.connecting)
        guard central?.state == .poweredOn else { return } // continues in centralManagerDidUpdateState
        connectTarget()
    }

    private func connectTarget() {
        guard let central, let id = targetID else { onStateChange?(.disconnected("Nie je vybrané žiadne zariadenie.")); return }
        let p = central.retrievePeripherals(withIdentifiers: [id]).first
            ?? central.retrieveConnectedPeripherals(withServices: [CBUUID(string: MeshtasticBLE.service)]).first { $0.identifier == id }
        guard let p else {
            // not known to iOS any more: scan, connect when it shows up
            startScan()
            return
        }
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    public func send(_ toRadio: Data) { session.send(toRadio) }

    public func stop() {
        wantConnect = false
        rssiTimer?.invalidate(); rssiTimer = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        session.reset()
        onStateChange?(.disconnected(nil))
    }

    // MARK: BLELink

    public func readFromRadio() {
        guard let p = peripheral, let c = fromRadio else { return }
        p.readValue(for: c)
    }

    public func writeToRadio(_ data: Data) {
        guard let p = peripheral, let c = toRadio else { return }
        p.writeValue(data, for: c, type: .withResponse)
    }

    public func subscribeFromNum() {
        guard let p = peripheral, let c = fromNum else { return }
        p.setNotifyValue(true, for: c)
    }

    fileprivate func characteristicsFound() {
        guard toRadio != nil, fromRadio != nil, fromNum != nil else { return }
        session.linkReady()
        onStateChange?(.connected)
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.peripheral?.readRSSI() }
        }
    }

    static func describe(_ s: CBManagerState) -> String? {
        switch s {
        case .poweredOn: nil
        case .poweredOff: "Bluetooth je vypnutý. Zapnite ho v Ovládacom centre alebo v Nastaveniach."
        case .unauthorized: "psst lab nemá povolený Bluetooth. Nastavenia → psst lab → Bluetooth."
        case .unsupported: "Toto zariadenie nepodporuje Bluetooth LE (napr. simulátor)."
        case .resetting: "Bluetooth sa reštartuje…"
        default: "Bluetooth zatiaľ nie je pripravený."
        }
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            onBluetoothState?(Self.describe(central.state))
            guard central.state == .poweredOn else { return }
            if wantScan { startScan() }
            if wantConnect, peripheral == nil { connectTarget() }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Meshtastic"
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            discovered[id] = DiscoveredRadio(id: id, name: name, rssi: rssi, lastSeen: Date())
            onDiscovered?(discovered.values.sorted { $0.rssi > $1.rssi })
            if wantConnect, self.peripheral == nil, id == targetID {
                self.peripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            if !wantScan { central.stopScan() }
            peripheral.discoverServices([CBUUID(string: MeshtasticBLE.service), CBUUID(string: MeshtasticBLE.batteryService)])
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription
        MainActor.assumeIsolated {
            self.peripheral = nil
            onStateChange?(.disconnected(msg ?? "Pripojenie zlyhalo."))
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription
        MainActor.assumeIsolated {
            session.reset()
            toRadio = nil; fromRadio = nil; fromNum = nil
            rssiTimer?.invalidate(); rssiTimer = nil
            onStateChange?(.disconnected(msg))
            if wantConnect {
                // radio out of range / rebooted: iOS keeps a pending connect request open without timeout
                central.connect(peripheral, options: nil)
            } else {
                self.peripheral = nil
            }
        }
    }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in peripheral.services ?? [] {
                if s.uuid == CBUUID(string: MeshtasticBLE.service) {
                    peripheral.discoverCharacteristics([CBUUID(string: MeshtasticBLE.toRadio), CBUUID(string: MeshtasticBLE.fromRadio),
                                                        CBUUID(string: MeshtasticBLE.fromNum)], for: s)
                } else if s.uuid == CBUUID(string: MeshtasticBLE.batteryService) {
                    peripheral.discoverCharacteristics([CBUUID(string: MeshtasticBLE.batteryLevel)], for: s)
                }
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                switch c.uuid {
                case CBUUID(string: MeshtasticBLE.toRadio): toRadio = c
                case CBUUID(string: MeshtasticBLE.fromRadio): fromRadio = c
                case CBUUID(string: MeshtasticBLE.fromNum): fromNum = c
                case CBUUID(string: MeshtasticBLE.batteryLevel):
                    peripheral.readValue(for: c)
                    peripheral.setNotifyValue(true, for: c)
                default: break
                }
            }
            characteristicsFound()
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            switch uuid {
            case CBUUID(string: MeshtasticBLE.fromRadio):
                session.didRead(value, error: error)
                if error != nil, readErrors < 10 {
                    // typically "insufficient authentication" while the PIN dialog is open — try again shortly
                    readErrors += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.session.drain() }
                } else if error == nil {
                    readErrors = 0
                }
            case CBUUID(string: MeshtasticBLE.fromNum): session.didNotifyFromNum()
            case CBUUID(string: MeshtasticBLE.batteryLevel): if let b = value?.first { onBattery?(Int(b)) }
            default: break
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { session.didWrite(error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let v = RSSI.intValue
        MainActor.assumeIsolated { onRSSI?(v) }
    }
}
