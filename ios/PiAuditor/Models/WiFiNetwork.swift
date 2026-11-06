import Foundation

public struct WiFiNetwork: Identifiable, Codable, Hashable {
    public var id: String { "\(bssid.lowercased())-\(ssid)" }
    public let ssid: String
    public let bssid: String
    public let channel: String
    public let signal: Int
    public let security: String
    
    enum CodingKeys: String, CodingKey {
        case ssid
        case bssid
        case channel
        case signal
        case security
    }
    
    public init(ssid: String, bssid: String, channel: String, signal: Int, security: String) {
        self.ssid = ssid.isEmpty ? "<Hidden SSID>" : ssid
        self.bssid = bssid
        self.channel = channel
        self.signal = signal
        self.security = security
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSSID = try container.decodeIfPresent(String.self, forKey: .ssid) ?? ""
        self.ssid = rawSSID.isEmpty ? "<Hidden SSID>" : rawSSID
        self.bssid = try container.decodeIfPresent(String.self, forKey: .bssid) ?? ""
        
        // Flexibly decode channel as Int, String, or Double
        if let chInt = try? container.decode(Int.self, forKey: .channel) {
            self.channel = String(chInt)
        } else if let chStr = try? container.decode(String.self, forKey: .channel) {
            self.channel = chStr
        } else if let chDbl = try? container.decode(Double.self, forKey: .channel) {
            self.channel = String(Int(chDbl))
        } else {
            self.channel = "1"
        }
        
        // Flexibly decode signal (RSSI or percentage)
        if let sigInt = try? container.decode(Int.self, forKey: .signal) {
            self.signal = sigInt
        } else if let sigDbl = try? container.decode(Double.self, forKey: .signal) {
            self.signal = Int(sigDbl)
        } else {
            self.signal = -80
        }
        
        self.security = try container.decodeIfPresent(String.self, forKey: .security) ?? "WPA2"
    }
    
    /// True if network is operating on 5GHz spectrum (Channels 36-165)
    public var is5GHz: Bool {
        if let chNum = Int(channel) {
            return chNum > 14
        }
        return false
    }
    
    /// Normalizes RSSI (e.g. -40 to -90 dBm) or raw percentage to 0-100%
    public var signalPercentage: Int {
        if signal > 0 {
            return min(signal, 100)
        }
        // RSSI standard mapping: -30 dBm -> 100%, -90 dBm -> 0%
        let quality = 2 * (signal + 100)
        return min(max(quality, 5), 100)
    }
    
    /// Human-friendly RSSI string
    public var signalFormatted: String {
        if signal < 0 {
            return "\(signal) dBm"
        }
        return "\(signal)%"
    }
}
