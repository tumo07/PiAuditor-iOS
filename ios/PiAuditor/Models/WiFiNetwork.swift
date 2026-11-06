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
        case rssi
        case security
        case crypto
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
        
        // Flexibly decode signal from "signal" or "rssi"
        if let sigInt = try? container.decode(Int.self, forKey: .signal) {
            self.signal = sigInt
        } else if let rssiInt = try? container.decode(Int.self, forKey: .rssi) {
            self.signal = rssiInt
        } else if let sigDbl = try? container.decode(Double.self, forKey: .signal) {
            self.signal = Int(sigDbl)
        } else if let rssiDbl = try? container.decode(Double.self, forKey: .rssi) {
            self.signal = Int(rssiDbl)
        } else {
            self.signal = -80
        }
        
        // Flexibly decode security from "security" or "crypto"
        if let sec = try? container.decode(String.self, forKey: .security), !sec.isEmpty {
            self.security = sec
        } else if let cry = try? container.decode(String.self, forKey: .crypto), !cry.isEmpty {
            self.security = cry
        } else {
            self.security = "WPA2"
        }
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

/// Represents an aggregated group of BSSIDs sharing the same SSID (mesh / dual-band / multi-AP)
public struct WiFiNetworkGroup: Identifiable, Hashable {
    public var id: String { ssid }
    public let ssid: String
    public var networks: [WiFiNetwork]
    
    public var isDualBand: Bool {
        let has24 = networks.contains { !$0.is5GHz }
        let has5 = networks.contains { $0.is5GHz }
        return has24 && has5
    }
    
    public var bandBadge: String {
        if isDualBand { return "2.4G + 5G" }
        if let first = networks.first {
            return first.is5GHz ? "5 GHz" : "2.4 GHz"
        }
        return "2.4 GHz"
    }
    
    public var primaryNetwork: WiFiNetwork {
        // Strongest RSSI AP
        networks.max(by: { $0.signal < $1.signal }) ?? networks.first!
    }
    
    public var apCountString: String {
        let count = networks.count
        return count == 1 ? "1 AP" : "\(count) APs"
    }
    
    public var channelsSummary: String {
        let chs = networks.compactMap { Int($0.channel) }.sorted()
        return chs.map { "Ch \($0)" }.joined(separator: ", ")
    }
    
    public var maxSignalPercentage: Int {
        primaryNetwork.signalPercentage
    }
    
    public var maxSignalFormatted: String {
        primaryNetwork.signalFormatted
    }
    
    public var security: String {
        primaryNetwork.security
    }
}

extension Array where Element == WiFiNetwork {
    public func groupedBySSID() -> [WiFiNetworkGroup] {
        var dict: [String: [WiFiNetwork]] = [:]
        for net in self {
            dict[net.ssid, default: []].append(net)
        }
        return dict.map { (ssid, nets) in
            let sortedNets = nets.sorted(by: { $0.signal > $1.signal })
            return WiFiNetworkGroup(ssid: ssid, networks: sortedNets)
        }.sorted(by: { $0.primaryNetwork.signal > $1.primaryNetwork.signal })
    }
}
