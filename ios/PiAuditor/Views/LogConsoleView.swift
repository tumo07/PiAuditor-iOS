import SwiftUI

struct LogConsoleView: View {
    @ObservedObject var ble = BLEManager.shared
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Appliance Telemetry Stream")) {
                    if ble.logs.isEmpty {
                        Text("No events received yet.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(ble.logs, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(colorForLog(line))
                        }
                    }
                }
            }
            .navigationTitle("Event Console")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        ble.logs.removeAll()
                    }) {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
    
    private func colorForLog(_ line: String) -> Color {
        if line.contains("[!]") { return .red }
        if line.contains("[+]") || line.contains("HANDSHAKE") { return .green }
        if line.contains("[>]") { return .blue }
        return .primary
    }
}
