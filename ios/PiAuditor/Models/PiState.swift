import Foundation

public enum AuditorMode: String, Codable {
    case standby = "STANDBY"
    case portal = "PORTAL"
    case auditing = "AUDITING"
    case handshakeCaptured = "HANDSHAKE_CAPTURED"
    case error = "ERROR"
    
    public var displayTitle: String {
        switch self {
        case .standby: return "Standby"
        case .portal: return "Portal Active"
        case .auditing: return "Auditing (Monitor)"
        case .handshakeCaptured: return "Handshake Captured"
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
