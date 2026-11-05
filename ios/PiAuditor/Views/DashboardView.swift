import SwiftUI

struct DashboardView: View {
    @ObservedObject var ble = BLEManager.shared
    @State private var showingAuditSheet = false
    @State private var selectedNetwork: WiFiNetwork?
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Connection Status Header Card
                    connectionHeaderCard
                    
                    // Live Appliance Telemetry Card
                    applianceTelemetryCard
                    
                    // Quick Action Buttons
                    actionButtonsSection
                    
                    // Discovered Target Networks
                    surveySectionHeader
                    
                    if ble.surveyedNetworks.isEmpty {
                        emptySurveyCard
                    } else {
                        ForEach(ble.surveyedNetworks) { net in
                            NetworkRowView(network: net) {
                                selectedNetwork = net
                                showingAuditSheet = true
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("PiAuditor")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        ble.requestSurvey()
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .sheet(item: $selectedNetwork) { net in
                AuditControlView(network: net)
            }
        }
    }
    
    private var connectionHeaderCard: some View {
        HStack {
            Image(systemName: ble.isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundColor(ble.isConnected ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(ble.isConnected ? "Connected to PiAuditor" : "Searching for PiAuditor-BLE...")
                    .font(.headline)
                Text(ble.isConnected ? "BLE Out-of-Band Link Active (RSSI: \(ble.deviceRSSI) dBm)" : "Keep Pi near your iPhone")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            Circle()
                .fill(ble.isConnected ? Color.green : Color.orange)
                .frame(width: 12, height: 12)
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var applianceTelemetryCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Operational State")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(ble.piState.mode.displayTitle)
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(modeBackgroundColor(ble.piState.mode))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            
            Divider()
            
            HStack(spacing: 20) {
                telemetryItem(title: "Handshakes", value: "\(ble.piState.handshakes)", icon: "lock.shield", color: .purple)
                telemetryItem(title: "Channel", value: ble.piState.channel > 0 ? "Ch \(ble.piState.channel)" : "Idle", icon: "wave.3.forward", color: .blue)
                telemetryItem(title: "Pi Temp", value: "\(ble.piState.cpuTemp)°C", icon: "thermometer.medium", color: .red)
            }
            
            if !ble.piState.targetSSID.isEmpty {
                Divider()
                HStack {
                    Text("Target:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(ble.piState.targetSSID)
                        .font(.caption)
                        .bold()
                    Spacer()
                    Text(ble.piState.targetBSSID)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            Button(action: {
                ble.requestSurvey()
            }) {
                Label("Scan Wi-Fi", systemImage: "sparkle.magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            if ble.piState.mode == .auditing {
                Button(action: {
                    ble.stopAudit()
                }) {
                    Label("Stop Audit", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
    }
    
    private var surveySectionHeader: some View {
        HStack {
            Text("Visible Networks (\(ble.surveyedNetworks.count))")
                .font(.headline)
            Spacer()
        }
        .padding(.top, 8)
    }
    
    private var emptySurveyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No surveyed networks loaded.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Tap 'Scan Wi-Fi' to survey nearby access points.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func telemetryItem(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.headline)
                .bold()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func modeBackgroundColor(_ mode: AuditorMode) -> Color {
        switch mode {
        case .standby: return .gray
        case .portal: return .blue
        case .auditing: return .orange
        case .handshakeCaptured: return .green
        case .error: return .red
        }
    }
}

struct NetworkRowView: View {
    let network: WiFiNetwork
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(network.ssid)
                        .font(.body)
                        .bold()
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text(network.bssid)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Ch \(network.channel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(network.security)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                    
                    HStack(spacing: 2) {
                        Image(systemName: signalIcon(network.signal))
                            .font(.caption)
                            .foregroundColor(signalColor(network.signal))
                        Text("\(network.signal)%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
    }
    
    private func signalIcon(_ sig: Int) -> String {
        if sig > 75 { return "wifi" }
        if sig > 50 { return "wifi" }
        if sig > 25 { return "wifi" }
        return "wifi.slash"
    }
    
    private func signalColor(_ sig: Int) -> Color {
        if sig > 75 { return .green }
        if sig > 50 { return .blue }
        if sig > 25 { return .orange }
        return .red
    }
}
