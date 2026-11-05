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
                
                LogConsoleView()
                    .tabItem {
                        Label("Console", systemImage: "terminal")
                    }
            }
        }
    }
}
