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
    @Published public var isGATTReady = false
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
        isGATTReady = false
        appendLog("[*] Scanning for PiAuditor-BLE...")
        // Discover any matching service or by name to bypass caching
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
            appendLog("[*] Channels synchronizing... Retrying '\(action)' in 1s.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.isConnected else { return }
                if let p2 = self.peripheral, let cmd2 = self.commandChar {
                    var dict: [String: Any] = ["action": action]
                    for (k, v) in parameters { dict[k] = v }
                    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
                        let type: CBCharacteristicWriteType = cmd2.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                        p2.writeValue(data, for: cmd2, type: type)
                        self.appendLog("[>] Dispatched CMD: \(action)")
                    }
                } else {
                    self.appendLog("[!] Cannot send command: Still synchronizing.")
                }
            }
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
    
    public func mergeSurveyNetworks(_ networks: [WiFiNetwork]) {
        DispatchQueue.main.async {
            for net in networks {
                if let idx = self.surveyedNetworks.firstIndex(where: { $0.bssid.caseInsensitiveCompare(net.bssid) == .orderedSame }) {
                    self.surveyedNetworks[idx] = net
                } else {
                    let isPriority = net.ssid.localizedCaseInsensitiveContains("luka") ||
                                     net.ssid.localizedCaseInsensitiveContains("o-dev") ||
                                     net.ssid.localizedCaseInsensitiveContains("odev")
                    if isPriority {
                        self.surveyedNetworks.insert(net, at: 0)
                    } else {
                        self.surveyedNetworks.append(net)
                    }
                }
            }
        }
    }
    
    public func readSurvey() {
        guard let p = peripheral, let sChar = surveyChar else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if let p2 = self?.peripheral, let s2 = self?.surveyChar {
                    p2.readValue(for: s2)
                }
            }
            Task {
                await APIService.shared.fetchSurvey()
            }
            return
        }
        p.readValue(for: sChar)
        Task {
            await APIService.shared.fetchSurvey()
        }
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
        readSurvey()
        Task {
            await APIService.shared.fetchSurvey()
        }
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
            isGATTReady = false
        case .unauthorized:
            appendLog("[!] Bluetooth permission unauthorized.")
        default:
            break
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        
        // Match PiAuditor-BLE by name or advertisement service
        let isPi = name.contains("PiAuditor") ||
                   (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(where: { $0.uuidString.lowercased().contains("a001") }) == true
        
        guard isPi else { return }
        
        appendLog("[+] Discovered: \(name) (RSSI: \(RSSI) dBm)")
        self.peripheral = peripheral
        self.deviceRSSI = RSSI.intValue
        self.stopScanning()
        self.centralManager.connect(peripheral, options: nil)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.isConnected = true
        self.isGATTReady = false
        self.hadHandshakeAlert = false
        appendLog("[+] Connected to PiAuditor!")
        peripheral.delegate = self
        // Discover all services to avoid stale GATT cache issues
        peripheral.discoverServices(nil)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.isConnected = false
        self.isGATTReady = false
        self.commandChar = nil
        self.surveyChar = nil
        self.statusChar = nil
        appendLog("[-] Disconnected from PiAuditor. Re-scanning...")
        startScanning()
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.isConnected = false
        self.isGATTReady = false
        appendLog("[!] Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            appendLog("[!] Service discovery error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            let sUUID = service.uuid.uuidString.lowercased()
            if sUUID.contains("a001") {
                appendLog("[+] Discovered PiAuditor Primary Service.")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            appendLog("[!] Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for ch in chars {
            let u = ch.uuid.uuidString.lowercased()
            if u.contains("a002") {
                self.statusChar = ch
                peripheral.setNotifyValue(true, for: ch)
                peripheral.readValue(for: ch)
                appendLog("[+] Status channel active.")
            } else if u.contains("a003") {
                self.commandChar = ch
                appendLog("[+] Command channel active.")
            } else if u.contains("a004") {
                self.surveyChar = ch
                peripheral.setNotifyValue(true, for: ch)
                peripheral.readValue(for: ch)
                appendLog("[+] Survey channel active.")
            }
        }
        
        if self.commandChar != nil && self.surveyChar != nil {
            DispatchQueue.main.async {
                self.isGATTReady = true
                self.appendLog("[★] Appliance channels fully synchronized!")
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let u = characteristic.uuid.uuidString.lowercased()
        
        if u.contains("a002") {
            do {
                let decoder = JSONDecoder()
                let state = try decoder.decode(PiState.self, from: data)
                let previousMode = self.piState.mode
                
                DispatchQueue.main.async {
                    self.piState = state
                    self.appendLog("[Status] \(state.mode.displayTitle) | Handshakes: \(state.handshakes) | Temp: \(state.cpuTemp)°C")
                    
                    if previousMode == .surveying && state.mode != .surveying {
                        self.appendLog("[*] Scan completed. Requesting updated visible networks...")
                        self.readSurvey()
                    }
                    
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
        } else if u.contains("a004") {
            let decoder = JSONDecoder()
            
            // 1. Array decode
            if let networks = try? decoder.decode([WiFiNetwork].self, from: data) {
                mergeSurveyNetworks(networks)
                appendLog("[Survey] Loaded \(networks.count) networks from initial batch.")
                return
            }
            
            // 2. Single object stream
            if let single = try? decoder.decode(WiFiNetwork.self, from: data) {
                mergeSurveyNetworks([single])
                return
            }
            
            // 3. Fallback: Array of raw dictionaries
            if let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var parsedNets: [WiFiNetwork] = []
                for item in rawArray {
                    let ssid = item["ssid"] as? String ?? ""
                    let bssid = item["bssid"] as? String ?? ""
                    let channel = "\(item["channel"] ?? 1)"
                    let sig = (item["signal"] as? Int) ?? (item["rssi"] as? Int) ?? -80
                    let sec = (item["security"] as? String) ?? (item["crypto"] as? String) ?? "WPA2"
                    parsedNets.append(WiFiNetwork(ssid: ssid, bssid: bssid, channel: channel, signal: sig, security: sec))
                }
                if !parsedNets.isEmpty {
                    mergeSurveyNetworks(parsedNets)
                    appendLog("[Survey] Loaded \(parsedNets.count) networks from fallback batch.")
                    return
                }
            }
            
            // 4. Fallback: Single dictionary or Completion packet
            if let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let done = rawDict["done"] as? Bool, done {
                    let total = rawDict["total"] as? Int ?? self.surveyedNetworks.count
                    appendLog("[Survey] Stream completed: \(total) networks active.")
                    return
                }
                if let bssid = rawDict["bssid"] as? String, !bssid.isEmpty {
                    let ssid = rawDict["ssid"] as? String ?? ""
                    let channel = "\(rawDict["channel"] ?? 1)"
                    let sig = (rawDict["signal"] as? Int) ?? (rawDict["rssi"] as? Int) ?? -80
                    let sec = (rawDict["security"] as? String) ?? (rawDict["crypto"] as? String) ?? "WPA2"
                    let net = WiFiNetwork(ssid: ssid, bssid: bssid, channel: channel, signal: sig, security: sec)
                    mergeSurveyNetworks([net])
                    return
                }
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        self.deviceRSSI = RSSI.intValue
    }
}
