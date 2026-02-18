//
//  BLEManager.swift
//  nRFapp
//

import CoreBluetooth
import os

struct Peripheral: Identifiable {
    let id: Int
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
}

final class BLEManager: NSObject, ObservableObject {

    static let NUS_SERVICE = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let NUS_TX      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify
    static let NUS_RX      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write/wwr

    static private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "BLE")

    private var central: CBCentralManager!
    private var connected: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?

    @Published var isSwitchedOn = false
    @Published var isConnected = false
    @Published var peripherals: [Peripheral] = []
    @Published var logLines: [String] = []

    // Latest parsed sensor values (for live display)
    @Published var latestTemp: Double?
    @Published var latestHumidity: Double?
    @Published var latestPressure: Double?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.nRFapp.ble.central"]
        )
    }

    private func log(_ s: String) {
        Self.logger.info("\(s, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.logLines.append(s)
            // Keep log buffer manageable
            if let count = self?.logLines.count, count > 200 {
                self?.logLines.removeFirst(count - 200)
            }
        }
    }

    // MARK: - Public API

    func startScanning() {
        peripherals.removeAll()
        log("Starting scan…")
        central.scanForPeripherals(withServices: [Self.NUS_SERVICE],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        log("Scanning stopped")
        central.stopScan()
    }

    func connectPeripheral(_ p: CBPeripheral) {
        if let c = connected { central.cancelPeripheralConnection(c) }
        log("Connecting to \(p.name ?? "<no name>")")
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let c = connected { central.cancelPeripheralConnection(c) }
    }

    func send(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        send(data: data)
    }

    func send(data: Data) {
        guard let c = connected, let rx = rxCharacteristic else {
            log("send(): not connected or no RX characteristic"); return
        }
        let writeType: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        c.writeValue(data, for: rx, type: writeType)
        log("→ \(String(data: data, encoding: .utf8) ?? "\(data as NSData)")")
    }

    // MARK: - Incoming Data Parsing

    private func handleIncoming(text: String) {
        // Expected format: "Temp: 19.37 C, Hum: 52.82 %, Pres: 1013.25 hPa"
        let pattern = #"Temp:\s*([-+]?[0-9]*\.?[0-9]+).*?Hum:\s*([-+]?[0-9]*\.?[0-9]+).*?Pres:\s*([-+]?[0-9]*\.?[0-9]+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            log("Regex compile error"); return
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            log("Could not parse: \(text)"); return
        }

        func extract(_ i: Int) -> Double? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return Double(text[r])
        }

        guard let t = extract(1), let h = extract(2), let p = extract(3) else {
            log("Failed to extract numbers from: \(text)"); return
        }

        log("Parsed → T=\(String(format: "%.2f", t))°C  H=\(String(format: "%.1f", h))%  P=\(String(format: "%.1f", p))hPa")

        // ✅ Fixed: BME280 pressure range is 300–1100 hPa, not 0–1
       

        // Update live display values
        DispatchQueue.main.async { [weak self] in
            self?.latestTemp = t
            self?.latestHumidity = h
            self?.latestPressure = p
        }

        // Route to SessionManager for upload
        SessionManager.shared.ingestReading(tempC: t, humPct: h, presHpa: p)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isSwitchedOn = (central.state == .poweredOn)
        log("Central state: \(central.state.rawValue)")
        if isSwitchedOn { startScanning() } else { stopScanning() }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                      ?? peripheral.name ?? "Unknown"
        if peripherals.contains(where: { $0.peripheral.identifier == peripheral.identifier }) { return }

        let p = Peripheral(id: peripherals.count, name: advName, rssi: RSSI.intValue, peripheral: peripheral)
        peripherals.append(p)
        log("Discovered: \(advName)  RSSI:\(RSSI)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected: \(peripheral.name ?? "<no name>")")
        stopScanning()
        connected = peripheral
        isConnected = true
        rxCharacteristic = nil
        txCharacteristic = nil
        peripheral.delegate = self
        peripheral.discoverServices([Self.NUS_SERVICE])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log("Fail to connect: \(error?.localizedDescription ?? "unknown")")
        isConnected = false
        connected = nil
        startScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "normal")")
        isConnected = false
        connected = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = restored.first {
            connected = peripheral
            isConnected = (peripheral.state == .connected || peripheral.state == .connecting)
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.NUS_SERVICE])
            } else {
                central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { log("discoverServices error: \(e.localizedDescription)") }
        guard let services = peripheral.services, !services.isEmpty else {
            log("No services found"); return
        }
        for s in services where s.uuid == Self.NUS_SERVICE {
            log("NUS service found")
            peripheral.discoverCharacteristics(nil, for: s)
            return
        }
        log("NUS service not found")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let e = error { log("discoverCharacteristics error: \(e.localizedDescription)") }
        guard let chars = service.characteristics, !chars.isEmpty else {
            log("No characteristics"); return
        }
        for ch in chars {
            if ch.properties.contains(.notify) {
                txCharacteristic = ch
                peripheral.setNotifyValue(true, for: ch)
                log("TX (notify): \(ch.uuid)")
            }
            if ch.properties.contains(.writeWithoutResponse) || ch.properties.contains(.write) {
                rxCharacteristic = ch
                log("RX (write): \(ch.uuid)")
            }
        }
        if txCharacteristic == nil && rxCharacteristic == nil {
            log("⚠️ No suitable TX/RX characteristics found")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("notifyState error: \(e.localizedDescription)") }
        else { log("Notifications \(characteristic.isNotifying ? "enabled" : "disabled")") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("didUpdateValue error: \(e.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        let text = String(data: data, encoding: .utf8) ?? "\(data as NSData)"
        log("← \(text)")
        handleIncoming(text: text)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("didWriteValue error: \(e.localizedDescription)") }
        else { log("Write OK") }
    }
}
