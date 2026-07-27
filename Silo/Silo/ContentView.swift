import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Status", systemImage: "antenna.radiowaves.left.and.right") }

            DestinationView()
                .tabItem { Label("Server", systemImage: "externaldrive.connected.to.line.below") }

            BackupView()
                .tabItem { Label("Backup", systemImage: "arrow.triangle.2.circlepath") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

#Preview {
    ContentView()
}
