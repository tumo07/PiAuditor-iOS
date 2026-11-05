import Foundation

public struct WiFiNetwork: Identifiable, Codable, Hashable {
    public var id: String { bssid }
    public let ssid: String
    public let bssid: String
    public let channel: String
    public let signal: Int
    public let security: String
    
    public init(ssid: String, bssid: String, channel: String, signal: Int, security: String) {
        self.ssid = ssid.isEmpty ? "<Hidden SSID>" : ssid
        self.bssid = bssid
        self.channel = channel
        self.signal = signal
        self.security = security
    }
}
