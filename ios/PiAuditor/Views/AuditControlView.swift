import SwiftUI

struct AuditControlView: View {
    @Environment(\.presentationMode) var presentationMode
    let network: WiFiNetwork
    @ObservedObject var ble = BLEManager.shared
    
    @State private var bursts: Int = 3
    @State private var deauthBurstPacing: Double = 0.2
    @State private var silentWindow: Double = 8.0
    @State private var confirmLaunch = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Target Network")) {
                    HStack {
                        Text("SSID")
                        Spacer()
                        Text(network.ssid).bold()
                    }
                    HStack {
                        Text("BSSID")
                        Spacer()
                        Text(network.bssid).font(.footnote).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Channel & Band")
                        Spacer()
                        Text("Ch \(network.channel) (\(network.is5GHz ? "5 GHz" : "2.4 GHz"))")
                            .foregroundColor(network.is5GHz ? .purple : .blue)
                            .bold()
                    }
                    HStack {
                        Text("Security")
                        Spacer()
                        Text(network.security).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Signal Strength")
                        Spacer()
                        Text(network.signalFormatted)
                            .foregroundColor(signalColor(network.signalPercentage))
                            .bold()
                    }
                }
                
                Section(header: Text("Autonomous Audit Strategy")) {
                    Stepper(value: $bursts, in: 1...6) {
                        HStack {
                            Text("Micro-Bursts")
                            Spacer()
                            Text("\(bursts) cycles").foregroundColor(.secondary)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Inter-Frame Pacing")
                            Spacer()
                            Text("\(String(format: "%.1f", deauthBurstPacing))s").foregroundColor(.secondary)
                        }
                        Slider(value: $deauthBurstPacing, in: 0.1...1.0, step: 0.1)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Passive Listening Window")
                            Spacer()
                            Text("\(Int(silentWindow))s").foregroundColor(.secondary)
                        }
                        Slider(value: $silentWindow, in: 4.0...15.0, step: 1.0)
                    }
                }
                
                Section(footer: Text("The Pi will isolate wlan0 to monitor mode (wlan0mon) on Channel \(network.channel). BLE command and telemetry stay active.")) {
                    Button(action: {
                        confirmLaunch = true
                    }) {
                        HStack {
                            Spacer()
                            Label("Launch Autonomous Audit", systemImage: "bolt.shield.fill")
                                .bold()
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.orange)
                }
            }
            .navigationTitle("Audit Target")
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
            .alert(isPresented: $confirmLaunch) {
                Alert(
                    title: Text("Confirm Target Audit"),
                    message: Text("Are you authorized to assess '\(network.ssid)'? The Pi will isolate wlan0 and transmit composite bursts to elicit a 4-way handshake."),
                    primaryButton: .destructive(Text("Authorize & Start")) {
                        ble.startAudit(network: network, bursts: bursts, pacing: deauthBurstPacing)
                        presentationMode.wrappedValue.dismiss()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
    
    private func signalColor(_ sig: Int) -> Color {
        if sig > 70 { return .green }
        if sig > 40 { return .blue }
        if sig > 20 { return .orange }
        return .red
    }
}
