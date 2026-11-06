import Foundation

public struct StationClient: Identifiable, Codable, Hashable {
    public var id: String { mac }
    public let mac: String
    public let signal: Int
    public let packets: Int
    public let role: String
    
    enum CodingKeys: String, CodingKey {
        case mac
        case signal
        case packets
        case role
    }
    
    public init(mac: String, signal: Int = -50, packets: Int = 1, role: String = "Station (Client)") {
        self.mac = mac
        self.signal = signal
        self.packets = packets
        self.role = role
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mac = try container.decodeIfPresent(String.self, forKey: .mac) ?? "Unknown"
        self.signal = try container.decodeIfPresent(Int.self, forKey: .signal) ?? -50
        self.packets = try container.decodeIfPresent(Int.self, forKey: .packets) ?? 1
        self.role = try container.decodeIfPresent(String.self, forKey: .role) ?? "Station (Client)"
    }
}

public struct CaptureItem: Identifiable, Codable, Hashable {
    public var id: String { filename }
    public let filename: String
    public let basename: String
    public let ssid: String
    public let bssid: String
    public let channel: Int
    public let size: String
    public let duration: String
    public let packets: Int
    public let timeStr: String
    public let status: String
    public let hasHandshake: Bool
    public let hasPmkid: Bool
    public let has22000: Bool
    public let cracked: Bool
    public let password: String?
    public let hashcatFile: String?
    public let hashString: String?
    public let isActive: Bool?
    
    // Deep Telemetry fields from /api/inspect
    public let m1Count: Int?
    public let m2Count: Int?
    public let m3Count: Int?
    public let m4Count: Int?
    public let eapolPairs: Int?
    public let eapolTotal: Int?
    public let deauths: Int?
    public let disassocs: Int?
    public let rcChecked: Bool?
    public let apSignal: Int?
    public let clientSignal: Int?
    public let signalDelta: Int?
    public let clients: [StationClient]?
    
    enum CodingKeys: String, CodingKey {
        case filename
        case basename
        case ssid
        case bssid
        case channel
        case size
        case duration
        case packets
        case timeStr = "time_str"
        case status
        case hasHandshake = "has_handshake"
        case hasPmkid = "has_pmkid"
        case has22000 = "has_22000"
        case cracked
        case password
        case hashcatFile = "hashcat_file"
        case hashString = "hash_string"
        case isActive = "is_active"
        
        case m1Count = "m1_count"
        case m2Count = "m2_count"
        case m3Count = "m3_count"
        case m4Count = "m4_count"
        case eapolPairs = "eapol_pairs"
        case eapolTotal = "eapol_total"
        case deauths
        case disassocs
        case rcChecked = "rc_checked"
        case apSignal = "ap_signal"
        case clientSignal = "client_signal"
        case signalDelta = "signal_delta"
        case clients
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        self.basename = try container.decodeIfPresent(String.self, forKey: .basename) ?? ""
        self.ssid = try container.decodeIfPresent(String.self, forKey: .ssid) ?? "Unknown"
        self.bssid = try container.decodeIfPresent(String.self, forKey: .bssid) ?? ""
        self.channel = try container.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        self.size = try container.decodeIfPresent(String.self, forKey: .size) ?? "0 KB"
        self.duration = try container.decodeIfPresent(String.self, forKey: .duration) ?? "0s"
        self.packets = try container.decodeIfPresent(Int.self, forKey: .packets) ?? 0
        self.timeStr = try container.decodeIfPresent(String.self, forKey: .timeStr) ?? ""
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "PASSIVE_ONLY"
        self.hasHandshake = try container.decodeIfPresent(Bool.self, forKey: .hasHandshake) ?? false
        self.hasPmkid = try container.decodeIfPresent(Bool.self, forKey: .hasPmkid) ?? false
        self.has22000 = try container.decodeIfPresent(Bool.self, forKey: .has22000) ?? false
        self.cracked = try container.decodeIfPresent(Bool.self, forKey: .cracked) ?? false
        self.password = try container.decodeIfPresent(String.self, forKey: .password)
        self.hashcatFile = try container.decodeIfPresent(String.self, forKey: .hashcatFile)
        self.hashString = try container.decodeIfPresent(String.self, forKey: .hashString)
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
        
        self.m1Count = try container.decodeIfPresent(Int.self, forKey: .m1Count)
        self.m2Count = try container.decodeIfPresent(Int.self, forKey: .m2Count)
        self.m3Count = try container.decodeIfPresent(Int.self, forKey: .m3Count)
        self.m4Count = try container.decodeIfPresent(Int.self, forKey: .m4Count)
        self.eapolPairs = try container.decodeIfPresent(Int.self, forKey: .eapolPairs)
        self.eapolTotal = try container.decodeIfPresent(Int.self, forKey: .eapolTotal)
        self.deauths = try container.decodeIfPresent(Int.self, forKey: .deauths)
        self.disassocs = try container.decodeIfPresent(Int.self, forKey: .disassocs)
        self.rcChecked = try container.decodeIfPresent(Bool.self, forKey: .rcChecked)
        self.apSignal = try container.decodeIfPresent(Int.self, forKey: .apSignal)
        self.clientSignal = try container.decodeIfPresent(Int.self, forKey: .clientSignal)
        self.signalDelta = try container.decodeIfPresent(Int.self, forKey: .signalDelta)
        self.clients = try container.decodeIfPresent([StationClient].self, forKey: .clients)
    }
    
    public var isValidHandshake: Bool {
        hasHandshake || has22000 || (status == "VALID_HANDSHAKE")
    }
}
