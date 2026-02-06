//
//  BLEManager.swift
//  nRFapp
//
//  Created by heartbrokenboy on 9/17/25.
//

//central：iphone； peripheral：Nordic dev kit
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

    // 你目前代码里的自定义 UUID（先保留服务 UUID；特征用“属性识别法”更稳妥）
    //static private let NUS_SERVICE = CBUUID(string: "000062c4-b99e-4141-9439-c4f9db977899")
    static private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "BLE")

    private var central: CBCentralManager!
    private var connected: CBPeripheral?

    private var rxCharacteristic: CBCharacteristic? // 写入到这里 (RX on peripheral)
    private var txCharacteristic: CBCharacteristic? // 从这里接收通知 (TX on peripheral)

    @Published var isSwitchedOn = false
    @Published var isConnected = false
    @Published var peripherals: [Peripheral] = []
    
    @Published var logLines: [String] = [] // 简单日志/收发显示

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
        }
    }

    // MARK: - Public API

    func startScanning() {
        peripherals.removeAll()
        log("Starting scan")
        // 过滤服务可以更快更准：如果固件广告里没有完整服务 UUID，也可设置 nil + 名称过滤
        central.scanForPeripherals(withServices: [Self.NUS_SERVICE], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        log("Stopping scan")
        central.stopScan()
    }

    func connectPeripheral(_ p: CBPeripheral) {
        if let c = connected {
            central.cancelPeripheralConnection(c)
        }
        log("Connecting to \(p.name ?? "<no name>")")
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let c = connected {
            central.cancelPeripheralConnection(c)
        }
    }

    /// 写入字符串（UTF8）
    func send(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        send(data: data)
    }

    /// 写入二进制
    func send(data: Data) {
        guard let c = connected, let rx = rxCharacteristic else {
            log("send(): not connected or no RX characteristic")
            return
        }
        let writeType: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        c.writeValue(data, for: rx, type: writeType)
        log("→ \(String(data: data, encoding: .utf8) ?? "\(data as NSData)")")
    }
    
    private func handleIncoming(text: String) {
        // Example: "Temp: 19.37 C, Hum: 52.82 %, Pres: 0.98 hPa"
        let pattern = #"Temp:\s*([-+]?[0-9]*\.?[0-9]+).*?Hum:\s*([-+]?[0-9]*\.?[0-9]+).*?Pres:\s*([-+]?[0-9]*\.?[0-9]+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            log("Regex compile error")
            return
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            log("Could not parse: \(text)")
            return
        }

        func extract(_ i: Int) -> Double? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return Double(text[r])
        }

        guard let t = extract(1), let h = extract(2), let p = extract(3) else {
            log("Failed to extract numbers from: \(text)")
            return
        }
        //let pressure_hpa = p * 10.0

        log("Parsed sensor line → T=\(t)°C, H=\(h)%, P=\(p)hPa")

        // Optional sanity checks
        guard (-40...85).contains(t), (0...100).contains(h), (0...1).contains(p) else {
            log("Out-of-range values, skipping upload")
            return
        }

        sendSensorReadingWithTime(tempC: t, humPct: h, presHpa: p)
    }

}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isSwitchedOn = (central.state == .poweredOn)
        log("Central state: \(central.state.rawValue)")
        if isSwitchedOn {
            startScanning()
        } else {
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber,) {
        // 名称过滤：课程里你们用 BISTABLE_VR 前缀
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unknown"
        //guard advName.hasPrefix("BISTABLE_VR") else { return }

        // 去重
        if peripherals.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            return
        }

        let newPeripheral = Peripheral(id: peripherals.count, name: advName, rssi: RSSI.intValue, peripheral: peripheral)
        peripherals.append(newPeripheral)
        log("Discovered: \(advName) RSSI:\(RSSI)")
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
        // 课堂 demo 常用自动重连；也可在 UI 提供按钮
        startScanning()
    }
    //RestoreState
    func centralManager(_ central:CBCentralManager,
                        willRestoreState dict:[String:Any]){
        if let restoredPeriphrals=dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            let peripheral=restoredPeriphrals.first{
                connected=peripheral
                isConnected = (peripheral.state == .connected || peripheral.state == .connecting)
                peripheral.delegate=self
            if peripheral.state == .connected{
                peripheral.discoverServices([Self.NUS_SERVICE])
            }else{
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
        // 找到 NUS 服务再查特征；若固件只暴露一个服务，这里也可直接用 services.first
        for s in services where s.uuid == Self.NUS_SERVICE {
            log("NUS service found: \(s.uuid)")
            peripheral.discoverCharacteristics(nil, for: s) // 传 nil → 全部枚举，便于属性识别
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

        // 自动识别：支持 notify → TX；支持 write/wwr → RX
        for ch in chars {
            if ch.properties.contains(.notify) {
                txCharacteristic = ch
                peripheral.setNotifyValue(true, for: ch)
                log("TX (notify) char: \(ch.uuid)")
            }
            if ch.properties.contains(.writeWithoutResponse) || ch.properties.contains(.write) {
                rxCharacteristic = ch
                log("RX (write) char: \(ch.uuid) props:\(ch.properties)")
            }
        }

        if txCharacteristic == nil && rxCharacteristic == nil {
            log("No suitable TX/RX characteristics found. Check UUIDs/firmware.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("notifyState error: \(e.localizedDescription)") }
        else { log("notifyState for \(characteristic.uuid): \(characteristic.isNotifying)") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("didUpdateValue error: \(e.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        let text = String(data: data, encoding: .utf8) ?? "\(data as NSData)"
        log("← \(text)")
        handleIncoming(text:text)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error { log("didWriteValue error: \(e.localizedDescription)") }
        else { log("didWriteValue OK for \(characteristic.uuid)") }
    }
}
