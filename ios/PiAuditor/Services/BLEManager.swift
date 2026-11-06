import Foundation
import CoreBluetooth
import Combine
#if canImport(UIKit)
import UIKit
#endif

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
    private var surveyChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var hadHandshakeAlert = false
    
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
    
    public func readSurvey() {
        guard let p = peripheral, let sChar = surveyChar else {
            appendLog("[!] Cannot read survey: Characteristic not discovered.")
            return
        }
        p.readValue(for: sChar)
    }
    
    public func startAudit(network: WiFiNetwork, bursts: Int = 3, pacing: Double = 0.2) {
        sendCommand(action: "START_AUDIT", parameters: [
            "ssid": network.ssid == "<Hidden SSID>" ? "" : network.ssid,
            "bssid": network.bssid,
            "channel": Int(network.channel) ?? 1,
            "bursts": bursts,
            "pacing": pacing
        ])
    }
    
    public func startManualAudit(ssid: String, bssid: String, channel: Int, bursts: Int = 3) {
        sendCommand(action: "START_AUDIT", parameters: [
            "ssid": ssid,
            "bssid": bssid,
            "channel": channel,
            "bursts": bursts
        ])
    }
    
    public func stopAudit() {
        sendCommand(action: "STOP_AUDIT")
    }
    
    public func requestSurvey() {
        sendCommand(action: "SURVEY")
        // Immediate read to fetch top priority APs
        readSurvey()
    }
    
    public func clearSurvey() {
        sendCommand(action: "CLEAR_SURVEY")
        self.surveyedNetworks = []
        appendLog("[*] Cleared surveyed network cache.")
    }
    
    public func rebootPi() {
        sendCommand(action: "REBOOT")
    }
    
    public func shutdownPi() {
        sendCommand(action: "SHUTDOWN")
    }
    
    public func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("[\(timestamp)] \(message)", at: 0)
        if logs.count > 150 {
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
        self.hadHandshakeAlert = false
        appendLog("[+] Connected to PiAuditor!")
        peripheral.delegate = self
        peripheral.discoverServices([BLEManager.serviceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.isConnected = false
        self.commandChar = nil
        self.surveyChar = nil
        self.statusChar = nil
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
                self.statusChar = ch
                peripheral.setNotifyValue(true, for: ch)
                peripheral.readValue(for: ch)
            } else if ch.uuid == BLEManager.commandCharUUID {
                self.commandChar = ch
            } else if ch.uuid == BLEManager.surveyCharUUID {
                self.surveyChar = ch
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
                let previousMode = self.piState.mode
                
                DispatchQueue.main.async {
                    self.piState = state
                    self.appendLog("[Status] \(state.mode.displayTitle) | Handshakes: \(state.handshakes) | Temp: \(state.cpuTemp)°C")
                    
                    // Trigger automatic survey read once surveying completes
                    if previousMode == .surveying && state.mode != .surveying {
                        self.appendLog("[*] Scan completed. Requesting updated visible networks...")
                        self.readSurvey()
                    }
                    
                    // Alert when handshake is captured
                    if state.handshakeCaptured && !self.hadHandshakeAlert {
                        self.hadHandshakeAlert = true
                        #if canImport(UIKit)
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        #endif
                        self.appendLog("[🎉 HANDSHAKE CAPTURED!] Target: \(state.targetSSID) on Ch \(state.channel)")
                    }
                }
            } catch {
                if let str = String(data: data, encoding: .utf8) {
                    appendLog("[Raw Status]: \(str)")
                }
            }
        } else if characteristic.uuid == BLEManager.surveyCharUUID {
            let decoder = JSONDecoder()
            
            // 1. Try decoding as an array of WiFiNetwork (from ReadValue)
            if let networks = try? decoder.decode([WiFiNetwork].self, from: data) {
                DispatchQueue.main.async {
                    for net in networks {
                        if let idx = self.surveyedNetworks.firstIndex(where: { $0.bssid == net.bssid && $0.ssid == net.ssid }) {
                            self.surveyedNetworks[idx] = net
                        } else {
                            self.surveyedNetworks.append(net)
                        }
                    }
                    self.appendLog("[Survey] Loaded \(networks.count) networks from batch.")
                }
                return
            }
            
            // 2. Try decoding as a single streamed WiFiNetwork object
            if let single = try? decoder.decode(WiFiNetwork.self, from: data) {
                DispatchQueue.main.async {
                    if let idx = self.surveyedNetworks.firstIndex(where: { $0.bssid == single.bssid && $0.ssid == single.ssid }) {
                        self.surveyedNetworks[idx] = single
                    } else {
                        // Priority targets at top (e.g. Luka, O-DEV)
                        let isPriority = single.ssid.localizedCaseInsensitiveContains("luka") ||
                                         single.ssid.localizedCaseInsensitiveContains("o-dev") ||
                                         single.ssid.localizedCaseInsensitiveContains("odev")
                        if isPriority {
                            self.surveyedNetworks.insert(single, at: 0)
                        } else {
                            self.surveyedNetworks.append(single)
                        }
                    }
                }
                return
            }
            
            // 3. Check for stream completion indicator: {"done": true, "total": N}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let done = json["done"] as? Bool, done {
                    let total = json["total"] as? Int ?? self.surveyedNetworks.count
                    DispatchQueue.main.async {
                        self.appendLog("[Survey] Stream finished: \(total) networks active.")
                    }
                }
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        self.deviceRSSI = RSSI.intValue
    }
}
