import SwiftUI

@main
struct SiloApp: App {
    init() {
        DebugLog.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
