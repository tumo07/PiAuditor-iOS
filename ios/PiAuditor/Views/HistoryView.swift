import SwiftUI
import UIKit

struct HistoryView: View {
    @StateObject private var api = APIService.shared
    @State private var selectedFilter: HistoryFilter = .all
    @State private var inspectingCapture: CaptureItem? = nil
    @State private var searchText = ""
    @State private var copiedHashFilename: String? = nil
    
    enum HistoryFilter: String, CaseIterable {
        case all = "All"
        case handshakes = "Handshakes"
        case cracked = "Cracked"
        case passive = "Passive"
    }
    
    var filteredItems: [CaptureItem] {
        api.historyItems.filter { item in
            let matchesSearch = searchText.isEmpty ||
                item.ssid.localizedCaseInsensitiveContains(searchText) ||
                item.bssid.localizedCaseInsensitiveContains(searchText) ||
                item.filename.localizedCaseInsensitiveContains(searchText)
            
            let matchesFilter: Bool
            switch selectedFilter {
            case .all:
                matchesFilter = true
            case .handshakes:
                matchesFilter = item.isValidHandshake
            case .cracked:
                matchesFilter = item.cracked
            case .passive:
                matchesFilter = !item.isValidHandshake && !item.cracked
            }
            
            return matchesSearch && matchesFilter
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Header Stats Summary
                    statsOverviewCard
                    
                    // Filter & Search Controls
                    filterControlsSection
                    
                    // Captures List
                    if api.isLoadingHistory && api.historyItems.isEmpty {
                        ProgressView("Loading forensic captures...")
                            .padding(.top, 40)
                    } else if filteredItems.isEmpty {
                        emptyStateCard
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredItems) { item in
                                captureRow(item)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Capture Vault")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await api.fetchHistory(refresh: true)
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .sheet(item: $inspectingCapture) { cap in
                PacketInspectView(capture: cap)
            }
            .refreshable {
                await api.fetchHistory(refresh: true)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var statsOverviewCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Forensic Evidence Repository")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(api.baseURLString.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: ":5000", with: ""))
                    .font(.caption2)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }
            
            Divider()
            
            HStack(spacing: 12) {
                statBox(title: "Total PCAPs", value: "\(api.historyItems.count)", icon: "externaldrive.fill", color: .indigo)
                statBox(title: "Handshakes", value: "\(api.historyItems.filter { $0.isValidHandshake }.count)", icon: "checkmark.seal.fill", color: .yellow)
                statBox(title: "Cracked", value: "\(api.historyItems.filter { $0.cracked }.count)", icon: "lock.open.fill", color: .green)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func statBox(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(value)
                .font(.title3)
                .bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }
    
    private var filterControlsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search capture, SSID, BSSID...", text: $searchText)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            
            Picker("Filter", selection: $selectedFilter) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
        }
    }
    
    private func captureRow(_ item: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.ssid)
                            .font(.headline)
                            .bold()
                        if item.isActive == true {
                            Text("RECORDING")
                                .font(.caption2)
                                .bold()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    Text(item.bssid.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                }
                Spacer()
                
                statusBadge(item)
            }
            
            Divider()
            
            HStack(spacing: 12) {
                Label("Ch \(item.channel)", systemImage: "wave.3.forward")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label(item.size, systemImage: "doc.zipper")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label("\(item.packets) pkts", systemImage: "tray.full")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label(item.duration, systemImage: "stopwatch")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            HStack(spacing: 10) {
                Button(action: {
                    inspectingCapture = item
                }) {
                    Label("Inspect Packets", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                
                if item.has22000, let hashStr = item.hashString, !hashStr.isEmpty {
                    Button(action: {
                        UIPasteboard.general.string = hashStr
                        copiedHashFilename = item.filename
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if copiedHashFilename == item.filename {
                                copiedHashFilename = nil
                            }
                        }
                    }) {
                        Label(copiedHashFilename == item.filename ? "Copied!" : "22000", systemImage: copiedHashFilename == item.filename ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .bold()
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func statusBadge(_ item: CaptureItem) -> some View {
        if item.cracked, let pwd = item.password {
            Text("CRACKED: \(pwd)")
                .font(.caption2)
                .bold()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(6)
        } else if item.isValidHandshake {
            Text("HANDSHAKE")
                .font(.caption2)
                .bold()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.yellow.opacity(0.9))
                .foregroundColor(.black)
                .cornerRadius(6)
        } else {
            Text("PASSIVE")
                .font(.caption2)
                .bold()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(UIColor.tertiarySystemBackground))
                .foregroundColor(.secondary)
                .cornerRadius(6)
        }
    }
    
    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No Captures Found")
                .font(.headline)
            Text("Run an audit on nearby Wi-Fi targets to generate evidence PCAPs.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}
