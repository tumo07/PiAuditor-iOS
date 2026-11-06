import Foundation
import Combine

@MainActor
public class APIService: ObservableObject {
    public static let shared = APIService()
    
    @Published public var baseURLString: String = "http://192.168.4.1:5000"
    @Published public var historyItems: [CaptureItem] = []
    @Published public var isLoadingHistory: Bool = false
    @Published public var lastError: String? = nil
    
    // Candidate Appliance Addresses: Hotspot default, Tailscale fallback
    private let candidateHosts = ["192.168.4.1", "100.106.145.105", "192.168.137.15"]
    
    private init() {
        Task {
            await autoDiscoverHost()
            await fetchHistory()
        }
    }
    
    public func setHost(_ host: String) {
        baseURLString = "http://\(host):5000"
        Task {
            await fetchHistory(refresh: true)
        }
    }
    
    public func autoDiscoverHost() async {
        for host in candidateHosts {
            let testURL = URL(string: "http://\(host):5000/api/status")!
            var req = URLRequest(url: testURL)
            req.timeoutInterval = 1.5
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.baseURLString = "http://\(host):5000"
                    return
                }
            } catch {
                continue
            }
        }
    }
    
    public func fetchSurvey() async {
        let urlStr = "\(baseURLString)/api/survey"
        guard let url = URL(string: urlStr) else { return }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4.0
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let decoder = JSONDecoder()
                if let networks = try? decoder.decode([WiFiNetwork].self, from: data), !networks.isEmpty {
                    BLEManager.shared.mergeSurveyNetworks(networks)
                    BLEManager.shared.appendLog("[Survey] Synchronized \(networks.count) networks via Appliance REST.")
                }
            }
        } catch {
            // Silently ignore REST survey failure if appliance is in monitor mode
        }
    }
    
    public func fetchHistory(refresh: Bool = false) async {
        isLoadingHistory = true
        lastError = nil
        
        let urlStr = "\(baseURLString)/api/history\(refresh ? "?refresh=1" : "")"
        guard let url = URL(string: urlStr) else {
            isLoadingHistory = false
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6.0
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let decoder = JSONDecoder()
                let items = try decoder.decode([CaptureItem].self, from: data)
                self.historyItems = items
            } else {
                // Try fallback discovery if primary failed
                await autoDiscoverHost()
            }
        } catch {
            self.lastError = error.localizedDescription
            // If failed on current host, attempt candidate host switch
            await autoDiscoverHost()
        }
        isLoadingHistory = false
    }
    
    public func inspect(filename: String) async throws -> CaptureItem {
        guard let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURLString)/api/inspect/\(encodedName)") else {
            throw URLError(.badURL)
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 6.0
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(CaptureItem.self, from: data)
    }
    
    public func saveCracked(bssid: String, ssid: String, password: String) async throws {
        guard let url = URL(string: "\(baseURLString)/api/cracked") else {
            throw URLError(.badURL)
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5.0
        
        let body: [String: String] = [
            "bssid": bssid,
            "ssid": ssid,
            "password": password
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        // Refresh local history to update cracked badge
        await fetchHistory(refresh: true)
    }
}
