import Foundation
import CoreBluetooth
import Combine

public class BLEManager: NSObject, ObservableObject {
    public static let shared = BLEManager()
    
    public static let serviceUUID = CBUUID(string: "0000a001-0000-1000-8000-00805f9b34fb")
    public static let statusCharUUID = CBUUID(string: "0000a002-0000-1000-8000-00805f9b34fb")
    public static let commandCharUUID = CBUUID(string: "0000a003-0000-1000-8000-00805f9b34fb")
    public static let surveyCharUUID = CBUUID(string: "0000a004-0000-1000-8000-00805f9b34fb")
    
    @Published public var isConnected = false
    @Published public var isScanning = false
    @Published public var deviceRSSI: Int = 0
    @Published public var piState: PiState = .initial
    @Published public var surveyedNetworks: [WiFiNetwork] = []
    @Published public var logs: [String] = []
    
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    
    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            appendLog("[!] Bluetooth is not powered on.")
            return
        }
        isScanning = true
        appendLog("[*] Scanning for PiAuditor-BLE...")
        centralManager.scanForPeripherals(withServices: [BLEManager.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    public func stopScanning() {
        isScanning = false
        centralManager.stopScan()
    }
    
    public func disconnect() {
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }
    
    public func sendCommand(action: String, parameters: [String: Any] = [:]) {
        guard let p = peripheral, let cmdChar = commandChar else {
            appendLog("[!] Cannot send command: PiAuditor is not connected.")
            return
        }
        
        var dict: [String: Any] = ["action": action]
        for (k, v) in parameters {
            dict[k] = v
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            let type: CBCharacteristicWriteType = cmdChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(data, for: cmdChar, type: type)
            appendLog("[>] Dispatched CMD: \(action)")
        } catch {
            appendLog("[!] JSON Serialization error: \(error.localizedDescription)")
        }
    }
    
    public func startAudit(network: WiFiNetwork) {
        sendCommand(action: "START_AUDIT", parameters: [
            "ssid": network.ssid,
            "bssid": network.bssid,
            "channel": Int(network.channel) ?? 1
        ])
    }
    
    public func stopAudit() {
        sendCommand(action: "STOP_AUDIT")
    }
    
    public func requestSurvey() {
        sendCommand(action: "SURVEY")
    }
    
    public func rebootPi() {
        sendCommand(action: "REBOOT")
    }
    
    public func shutdownPi() {
        sendCommand(action: "SHUTDOWN")
    }
    
    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("[\(timestamp)] \(message)", at: 0)
        if logs.count > 100 {
            logs.removeLast()
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog("[+] Bluetooth ready. Auto-initiating scan...")
            startScanning()
        case .poweredOff:
            appendLog("[-] Bluetooth powered off.")
            isConnected = false
        case .unauthorized:
            appendLog("[!] Bluetooth permission unauthorized.")
        default:
            break
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown Device"
        appendLog("[+] Discovered: \(name) (RSSI: \(RSSI) dBm)")
        
        self.peripheral = peripheral
        self.deviceRSSI = RSSI.intValue
        self.stopScanning()
        self.centralManager.connect(peripheral, options: nil)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.isConnected = true
        appendLog("[+] Connected to PiAuditor!")
        peripheral.delegate = self
        peripheral.discoverServices([BLEManager.serviceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.isConnected = false
        self.commandChar = nil
        appendLog("[-] Disconnected from PiAuditor. Re-scanning...")
        startScanning()
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.isConnected = false
        appendLog("[!] Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEManager.serviceUUID {
            peripheral.discoverCharacteristics([
                BLEManager.statusCharUUID,
                BLEManager.commandCharUUID,
                BLEManager.surveyCharUUID
            ], for: service)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars {
            if ch.uuid == BLEManager.statusCharUUID {
                peripheral.setNotifyValue(true, for: ch)
                peripheral.readValue(for: ch)
            } else if ch.uuid == BLEManager.commandCharUUID {
                self.commandChar = ch
            } else if ch.uuid == BLEManager.surveyCharUUID {
                peripheral.setNotifyValue(true, for: ch)
                peripheral.readValue(for: ch)
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        if characteristic.uuid == BLEManager.statusCharUUID {
            do {
                let decoder = JSONDecoder()
                let state = try decoder.decode(PiState.self, from: data)
                DispatchQueue.main.async {
                    self.piState = state
                    self.appendLog("[Status Update] Mode: \(state.mode.displayTitle) | Handshakes: \(state.handshakes) | Temp: \(state.cpuTemp)°C")
                }
            } catch {
                if let str = String(data: data, encoding: .utf8) {
                    appendLog("[Raw Status]: \(str)")
                }
            }
        } else if characteristic.uuid == BLEManager.surveyCharUUID {
            do {
                let decoder = JSONDecoder()
                let networks = try decoder.decode([WiFiNetwork].self, from: data)
                DispatchQueue.main.async {
                    self.surveyedNetworks = networks
                    self.appendLog("[Survey] Loaded \(networks.count) surveyed networks.")
                }
            } catch {
                // Ignore partial chunks
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        self.deviceRSSI = RSSI.intValue
    }
}
