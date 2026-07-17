import SwiftUI

@main
struct ExampleApp: App {
    @State private var appUpdater = AppUpdater.shared

    var body: some Scene {
        WindowGroup {
            Text("Example App")
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }
}
