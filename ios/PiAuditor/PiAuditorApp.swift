import SwiftUI

@main
struct PiAuditorApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "antenna.radiowaves.left.and.right")
                    }
                
                HistoryView()
                    .tabItem {
                        Label("Captures", systemImage: "tray.full.fill")
                    }
                
                LogConsoleView()
                    .tabItem {
                        Label("Console", systemImage: "terminal.fill")
                    }
            }
        }
    }
}
