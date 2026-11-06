import SwiftUI
import UIKit

struct PacketInspectView: View {
    let capture: CaptureItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var api = APIService.shared
    
    @State private var detailedItem: CaptureItem? = nil
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var inputPassword = ""
    @State private var isSavingPassword = false
    @State private var saveSuccess = false
    @State private var copiedHash = false
    @State private var copiedPassword = false
    
    var currentItem: CaptureItem {
        detailedItem ?? capture
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Forensic Summary Header Card
                    summaryHeaderCard
                    
                    // Handshake / Crack Status Banner
                    statusBanner
                    
                    // RF Asymmetry & Signal Balance
                    rfSignalCard
                    
                    // 4-Way Handshake EAPOL Matrix
                    eapolMatrixCard
                    
                    // Observed Client Stations
                    stationsCard
                    
                    // Mode 22000 Hashcat Export
                    hashcatCard
                    
                    // Password Cracking Vault
                    crackedVaultCard
                }
                .padding()
            }
            .navigationTitle("Packet Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadInspection()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var summaryHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentItem.ssid)
                        .font(.title2)
                        .bold()
                    Text(currentItem.bssid.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                }
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CH \(currentItem.channel)")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                    Text(currentItem.size)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            HStack(spacing: 20) {
                metricColumn(title: "Packets", value: "\(currentItem.packets)", icon: "tray.full.fill", color: .indigo)
                metricColumn(title: "Duration", value: currentItem.duration, icon: "stopwatch.fill", color: .orange)
                metricColumn(title: "Recorded", value: currentItem.timeStr.components(separatedBy: " ").first ?? "Recent", icon: "calendar", color: .secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var statusBanner: some View {
        HStack(spacing: 12) {
            if currentItem.cracked {
                Image(systemName: "lock.open.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CRACKED PASSWORD SECURED")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.green)
                    Text(currentItem.password ?? "Password in vault")
                        .font(.headline)
                        .fontDesign(.monospaced)
                }
            } else if currentItem.isValidHandshake {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VALID WPA HANDSHAKE CAPTURED")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.primary)
                    Text("Ready for Hashcat / John mode 22000 cracking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PASSIVE WIRELESS TRAFFIC")
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.primary)
                    Text("Beacon, probe response, and client frame data")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(
            currentItem.cracked ? Color.green.opacity(0.15) :
            (currentItem.isValidHandshake ? Color.yellow.opacity(0.15) : Color(UIColor.secondarySystemBackground))
        )
        .cornerRadius(12)
    }
    
    private var rfSignalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("RF Signal Asymmetry", systemImage: "waveform.path.ecg")
                .font(.headline)
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AP Signal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(currentItem.apSignal ?? -50) dBm")
                        .font(.title3)
                        .bold()
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text("Delta Asymmetry")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(currentItem.signalDelta ?? 0) dB")
                        .font(.title3)
                        .bold()
                        .foregroundColor((currentItem.signalDelta ?? 0) > 15 ? .orange : .green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Client Signal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(currentItem.clientSignal ?? -50) dBm")
                        .font(.title3)
                        .bold()
                }
            }
            
            ProgressView(value: Double(min(max(100 + (currentItem.apSignal ?? -50), 0), 100)), total: 100)
                .tint(.blue)
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var eapolMatrixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("4-Way Handshake & EAPOL Matrix", systemImage: "shield.checkered")
                    .font(.headline)
                Spacer()
                if currentItem.rcChecked == true {
                    Text("RC Checked")
                        .font(.caption2)
                        .bold()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                }
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                frameBox(name: "M1", title: "ANonce", count: currentItem.m1Count ?? 0)
                frameBox(name: "M2", title: "SNonce+MIC", count: currentItem.m2Count ?? 0)
                frameBox(name: "M3", title: "GTK", count: currentItem.m3Count ?? 0)
                frameBox(name: "M4", title: "Ack", count: currentItem.m4Count ?? 0)
            }
            
            Divider()
            
            HStack {
                Text("EAPOL Pairs: \(currentItem.eapolPairs ?? 0)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Total EAPOL: \(currentItem.eapolTotal ?? 0)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Deauths: \(currentItem.deauths ?? 0)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func frameBox(name: String, title: String, count: Int) -> some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.headline)
                .bold()
                .foregroundColor(count > 0 ? .green : .secondary)
            Text("\(count)")
                .font(.title2)
                .bold()
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(count > 0 ? Color.green.opacity(0.12) : Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }
    
    private var stationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Observed Client Stations (\(currentItem.clients?.count ?? 0))", systemImage: "macbook.and.iphone")
                .font(.headline)
            
            if let clients = currentItem.clients, !clients.isEmpty {
                VStack(spacing: 8) {
                    ForEach(clients) { client in
                        HStack {
                            Image(systemName: "wifi")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.mac.uppercased())
                                    .font(.caption)
                                    .bold()
                                    .fontDesign(.monospaced)
                                Text(client.role)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(client.signal) dBm")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        if client.id != clients.last?.id {
                            Divider()
                        }
                    }
                }
            } else {
                Text("No active client stations sniffed in this capture.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var hashcatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Hashcat Mode 22000 Export", systemImage: "terminal.fill")
                    .font(.headline)
                Spacer()
                if currentItem.has22000 || currentItem.hashString != nil {
                    Button(action: {
                        if let hashStr = currentItem.hashString {
                            UIPasteboard.general.string = hashStr
                            copiedHash = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedHash = false
                            }
                        }
                    }) {
                        Label(copiedHash ? "Copied!" : "Copy Hash", systemImage: copiedHash ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .bold()
                    }
                }
            }
            
            if let hashStr = currentItem.hashString, !hashStr.isEmpty {
                Text(hashStr)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(4)
                    .padding(8)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(8)
            } else {
                Text(currentItem.isValidHandshake ? "Mode 22000 hash available on appliance." : "No valid 4-way EAPOL pair in capture for mode 22000 extraction.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var crackedVaultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Password Vault", systemImage: "key.fill")
                .font(.headline)
            
            if currentItem.cracked, let pwd = currentItem.password {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Decrypted PSK / Password")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(pwd)
                            .font(.title3)
                            .bold()
                            .fontDesign(.monospaced)
                            .foregroundColor(.green)
                    }
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = pwd
                        copiedPassword = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedPassword = false
                        }
                    }) {
                        Image(systemName: copiedPassword ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Store cracked password for \(currentItem.ssid):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        SecureField("Enter cracked Wi-Fi password", text: $inputPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        Button(action: {
                            Task {
                                isSavingPassword = true
                                do {
                                    try await api.saveCracked(bssid: currentItem.bssid, ssid: currentItem.ssid, password: inputPassword)
                                    saveSuccess = true
                                    await loadInspection()
                                } catch {
                                    loadError = "Failed to save password: \(error.localizedDescription)"
                                }
                                isSavingPassword = false
                            }
                        }) {
                            if isSavingPassword {
                                ProgressView()
                            } else {
                                Text("Save")
                                    .bold()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputPassword.trimmingCharacters(in: .whitespaces).isEmpty || isSavingPassword)
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func metricColumn(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(value)
                .font(.subheadline)
                .bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func loadInspection() async {
        isLoading = true
        do {
            let fullItem = try await api.inspect(filename: capture.filename)
            self.detailedItem = fullItem
            if let pwd = fullItem.password {
                self.inputPassword = pwd
            }
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoading = false
    }
}
