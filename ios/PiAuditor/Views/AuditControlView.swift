import SwiftUI

struct AuditControlView: View {
    @Environment(\.presentationMode) var presentationMode
    let network: WiFiNetwork
    @ObservedObject var ble = BLEManager.shared
    
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
                        Text("Channel")
                        Spacer()
                        Text("Ch \(network.channel)").foregroundColor(.blue)
                    }
                    HStack {
                        Text("Signal Strength")
                        Spacer()
                        Text("\(network.signal)%")
                    }
                }
                
                Section(header: Text("Composite Injection Parameters")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Micro-Burst Pacing")
                            Spacer()
                            Text("\(String(format: "%.1f", deauthBurstPacing))s").foregroundColor(.secondary)
                        }
                        Slider(value: $deauthBurstPacing, in: 0.1...1.0, step: 0.1)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Silent Listening Window")
                            Spacer()
                            Text("\(Int(silentWindow))s").foregroundColor(.secondary)
                        }
                        Slider(value: $silentWindow, in: 4.0...15.0, step: 1.0)
                    }
                }
                
                Section(footer: Text("Audit Mode switches wlan0 to monitor mode (wlan0mon). The hotspot will power cycle, but your BLE connection stays active.")) {
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
                        .padding(.vertical, 6)
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
                        ble.startAudit(network: network)
                        presentationMode.wrappedValue.dismiss()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
}
