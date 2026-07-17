# AppKit integration

After `sparklekit integrate --apply`, add the official Sparkle package to the app target and ensure `SparkleReleaseKit/AppUpdater.swift` belongs to that target.

Keep the updater alive from `AppDelegate`:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appUpdater = AppUpdater.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Existing startup logic.
    }
}
```

Connect a menu item's action to:

```swift
AppUpdater.shared.checkForUpdates(sender)
```

The title should follow the normal macOS convention: **Check for Updates...**.
