import Foundation

public enum AuditorMode: String, Codable {
    case standby = "STANDBY"
    case portal = "PORTAL"
    case surveying = "SURVEYING"
    case auditing = "AUDITING"
    case handshakeCaptured = "HANDSHAKE_CAPTURED"
    case error = "ERROR"
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.uppercased() ?? "STANDBY"
        self = AuditorMode(rawValue: raw) ?? .standby
    }
    
    public var displayTitle: String {
        switch self {
        case .standby: return "Standby"
        case .portal: return "Portal Active"
        case .surveying: return "Surveying Wi-Fi..."
        case .auditing: return "Auditing (Monitor)"
        case .handshakeCaptured: return "Handshake Secured!"
        case .error: return "Error"
        }
    }
}

public struct PiState: Codable {
    public var mode: AuditorMode
    public var targetSSID: String
    public var targetBSSID: String
    public var channel: Int
    public var handshakes: Int
    public var clients: Int
    public var cpuTemp: Double
    public var event: String
    public var uptime: Int
    public var burstCurrent: Int
    public var burstTotal: Int
    public var packets: Int
    public var pcapSizeKb: Double
    public var handshakeCaptured: Bool
    
    enum CodingKeys: String, CodingKey {
        case mode
        case targetSSID = "target_ssid"
        case targetBSSID = "target_bssid"
        case channel
        case handshakes
        case clients
        case cpuTemp = "cpu_temp"
        case event
        case uptime
        case burstCurrent = "burst_current"
        case burstTotal = "bursts_total"
        case packets
        case pcapSizeKb = "pcap_size_kb"
        case handshakeCaptured = "handshake_captured"
    }
    
    public init(
        mode: AuditorMode,
        targetSSID: String,
        targetBSSID: String,
        channel: Int,
        handshakes: Int,
        clients: Int,
        cpuTemp: Double,
        event: String,
        uptime: Int,
        burstCurrent: Int = 0,
        burstTotal: Int = 3,
        packets: Int = 0,
        pcapSizeKb: Double = 0.0,
        handshakeCaptured: Bool = false
    ) {
        self.mode = mode
        self.targetSSID = targetSSID
        self.targetBSSID = targetBSSID
        self.channel = channel
        self.handshakes = handshakes
        self.clients = clients
        self.cpuTemp = cpuTemp
        self.event = event
        self.uptime = uptime
        self.burstCurrent = burstCurrent
        self.burstTotal = burstTotal
        self.packets = packets
        self.pcapSizeKb = pcapSizeKb
        self.handshakeCaptured = handshakeCaptured
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(AuditorMode.self, forKey: .mode) ?? .standby
        self.targetSSID = try container.decodeIfPresent(String.self, forKey: .targetSSID) ?? ""
        self.targetBSSID = try container.decodeIfPresent(String.self, forKey: .targetBSSID) ?? ""
        self.channel = try container.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        self.handshakes = try container.decodeIfPresent(Int.self, forKey: .handshakes) ?? 0
        self.clients = try container.decodeIfPresent(Int.self, forKey: .clients) ?? 0
        self.cpuTemp = try container.decodeIfPresent(Double.self, forKey: .cpuTemp) ?? 0.0
        self.event = try container.decodeIfPresent(String.self, forKey: .event) ?? ""
        self.uptime = try container.decodeIfPresent(Int.self, forKey: .uptime) ?? 0
        self.burstCurrent = try container.decodeIfPresent(Int.self, forKey: .burstCurrent) ?? 0
        self.burstTotal = try container.decodeIfPresent(Int.self, forKey: .burstTotal) ?? 3
        self.packets = try container.decodeIfPresent(Int.self, forKey: .packets) ?? 0
        
        if let dbl = try? container.decode(Double.self, forKey: .pcapSizeKb) {
            self.pcapSizeKb = dbl
        } else if let intVal = try? container.decode(Int.self, forKey: .pcapSizeKb) {
            self.pcapSizeKb = Double(intVal)
        } else {
            self.pcapSizeKb = 0.0
        }
        
        let hsCap = try container.decodeIfPresent(Bool.self, forKey: .handshakeCaptured) ?? false
        self.handshakeCaptured = hsCap || (self.handshakes > 0)
    }
    
    public static var initial: PiState {
        PiState(
            mode: .standby,
            targetSSID: "",
            targetBSSID: "",
            channel: 0,
            handshakes: 0,
            clients: 0,
            cpuTemp: 0.0,
            event: "Connecting to PiAuditor BLE...",
            uptime: 0
        )
    }
}
