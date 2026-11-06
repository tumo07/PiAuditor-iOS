import SwiftUI

struct DashboardView: View {
    @ObservedObject var ble = BLEManager.shared
    @State private var showingAuditSheet = false
    @State private var selectedNetwork: WiFiNetwork?
    @State private var showingManualSheet = false
    @State private var searchText = ""
    @State private var selectedBandFilter: BandFilter = .all
    
    enum BandFilter: String, CaseIterable {
        case all = "All"
        case fiveGHz = "5 GHz"
        case twoGHz = "2.4 GHz"
    }
    
    var filteredNetworks: [WiFiNetwork] {
        ble.surveyedNetworks.filter { net in
            let matchesSearch = searchText.isEmpty ||
                net.ssid.localizedCaseInsensitiveContains(searchText) ||
                net.bssid.localizedCaseInsensitiveContains(searchText)
            
            let matchesBand: Bool
            switch selectedBandFilter {
            case .all:
                matchesBand = true
            case .fiveGHz:
                matchesBand = net.is5GHz
            case .twoGHz:
                matchesBand = !net.is5GHz
            }
            
            return matchesSearch && matchesBand
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Connection Status Header Card
                    connectionHeaderCard
                    
                    // Live Appliance Telemetry Card
                    applianceTelemetryCard
                    
                    // Handshake Captured Celebration Banner (if captured)
                    if ble.piState.handshakeCaptured || ble.piState.handshakes > 0 {
                        handshakeSuccessBanner
                    }
                    
                    // Active Audit Live Telemetry (if auditing)
                    if ble.piState.mode == .auditing {
                        activeAuditCard
                    }
                    
                    // Action Buttons (Scan Wi-Fi / Stop Audit)
                    actionButtonsSection
                    
                    // Search & Band Filter
                    searchAndFilterSection
                    
                    // Discovered Target Networks
                    surveySectionHeader
                    
                    if ble.surveyedNetworks.isEmpty {
                        emptySurveyCard
                    } else if filteredNetworks.isEmpty {
                        noSearchResultsCard
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredNetworks) { net in
                                NetworkRowView(network: net) {
                                    selectedNetwork = net
                                    showingAuditSheet = true
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("PiAuditor")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: {
                            ble.requestSurvey()
                        }) {
                            Label("Scan Nearby Networks", systemImage: "sparkle.magnifyingglass")
                        }
                        
                        Button(action: {
                            ble.readSurvey()
                        }) {
                            Label("Refresh Network Table", systemImage: "arrow.triangle.2.circlepath")
                        }
                        
                        Button(action: {
                            showingManualSheet = true
                        }) {
                            Label("Manual Target Audit", systemImage: "plus.circle")
                        }
                        
                        Divider()
                        
                        Button(action: {
                            ble.clearSurvey()
                        }) {
                            Label("Clear Survey Cache", systemImage: "trash")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive, action: {
                            ble.rebootPi()
                        }) {
                            Label("Reboot Raspberry Pi", systemImage: "arrow.clockwise")
                        }
                        
                        Button(role: .destructive, action: {
                            ble.shutdownPi()
                        }) {
                            Label("Shut Down Pi", systemImage: "power")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                    }
                }
            }
            .sheet(item: $selectedNetwork) { net in
                AuditControlView(network: net)
            }
            .sheet(isPresented: $showingManualSheet) {
                ManualTargetAuditSheet()
            }
        }
    }
    
    // MARK: - Subviews
    
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
    
    private var handshakeSuccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title)
                .foregroundColor(.yellow)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("WPA Handshake Secured!")
                    .font(.headline)
                    .bold()
                    .foregroundColor(.white)
                Text(ble.piState.targetSSID.isEmpty ? "Stored in captures/" : "Target: \(ble.piState.targetSSID) (Ch \(ble.piState.channel))")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
            Spacer()
        }
        .padding()
        .background(Color.green)
        .cornerRadius(12)
    }
    
    private var activeAuditCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Audit In Progress", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.orange)
                Spacer()
                Text("Burst \(ble.piState.burstCurrent) of \(ble.piState.burstTotal)")
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(6)
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Intercepted")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(ble.piState.packets) pkts")
                        .font(.subheadline)
                        .bold()
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("PCAP Capture")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(String(format: "%.1f", ble.piState.pcapSizeKb)) KB")
                        .font(.subheadline)
                        .bold()
                }
                
                Spacer()
                
                Button(action: {
                    ble.stopAudit()
                }) {
                    Text("Abort")
                        .font(.caption)
                        .bold()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1.5)
        )
    }
    
    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            Button(action: {
                ble.requestSurvey()
            }) {
                HStack {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Scan Wi-Fi")
                        .bold()
                }
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
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Audit")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
    }
    
    private var searchAndFilterSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search networks (SSID, BSSID)...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
            
            Picker("Band", selection: $selectedBandFilter) {
                ForEach(BandFilter.allCases, id: \.self) { band in
                    Text(band.rawValue).tag(band)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
        }
    }
    
    private var surveySectionHeader: some View {
        HStack {
            Text("Visible Networks (\(filteredNetworks.count))")
                .font(.headline)
            Spacer()
            Button(action: {
                ble.readSurvey()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding(.top, 4)
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
    
    private var noSearchResultsCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("No networks match '\(searchText)'")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
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
        case .surveying: return .indigo
        case .auditing: return .orange
        case .handshakeCaptured: return .green
        case .error: return .red
        }
    }
}

// MARK: - Network Row Component
struct NetworkRowView: View {
    let network: WiFiNetwork
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(network.ssid)
                            .font(.body)
                            .bold()
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        // 5GHz vs 2.4GHz tag
                        Text(network.is5GHz ? "5G" : "2.4G")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(network.is5GHz ? Color.purple.opacity(0.18) : Color.gray.opacity(0.18))
                            .foregroundColor(network.is5GHz ? .purple : .secondary)
                            .cornerRadius(4)
                    }
                    
                    HStack(spacing: 6) {
                        Text(network.bssid)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("•")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Ch \(network.channel)")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.blue)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(network.security)
                        .font(.caption2)
                        .bold()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                    
                    HStack(spacing: 3) {
                        Image(systemName: signalIcon(network.signalPercentage))
                            .font(.caption)
                            .foregroundColor(signalColor(network.signalPercentage))
                        Text(network.signalFormatted)
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
        if sig > 60 { return "wifi" }
        if sig > 30 { return "wifi" }
        return "wifi.exclamationmark"
    }
    
    private func signalColor(_ sig: Int) -> Color {
        if sig > 60 { return .green }
        if sig > 35 { return .blue }
        if sig > 15 { return .orange }
        return .red
    }
}

// MARK: - Manual Target Sheet
struct ManualTargetAuditSheet: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var ble = BLEManager.shared
    
    @State private var ssid: String = ""
    @State private var bssid: String = ""
    @State private var channel: String = "149"
    @State private var bursts: Int = 3
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Target Parameters")) {
                    TextField("SSID (e.g. Luka or O-DEV)", text: $ssid)
                    TextField("BSSID (e.g. 9e:88:12:f1:08:7b)", text: $bssid)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Channel (e.g. 1, 6, 11, 149)", text: $channel)
                        .keyboardType(.numberPad)
                }
                
                Section(header: Text("Micro-Burst Pacing")) {
                    Stepper(value: $bursts, in: 1...6) {
                        HStack {
                            Text("Burst Count")
                            Spacer()
                            Text("\(bursts) cycles")
                        }
                    }
                }
                
                Section {
                    Button(action: {
                        guard let chNum = Int(channel), !bssid.isEmpty else { return }
                        ble.startManualAudit(ssid: ssid, bssid: bssid, channel: chNum, bursts: bursts)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Label("Launch Targeted Audit", systemImage: "bolt.shield.fill")
                                .bold()
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(bssid.isEmpty ? Color.gray : Color.orange)
                    .disabled(bssid.isEmpty)
                }
            }
            .navigationTitle("Manual Target")
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}
