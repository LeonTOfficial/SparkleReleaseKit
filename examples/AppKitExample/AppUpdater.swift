import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        controller.checkForUpdates(sender)
    }
}
