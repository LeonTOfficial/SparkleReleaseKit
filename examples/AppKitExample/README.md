# AppKit example

1. Add `https://github.com/sparkle-project/Sparkle` through Xcode's package dependency UI.
2. Link the `Sparkle` product to the macOS app target.
3. Add `AppUpdater.swift` to that target.
4. Keep `AppUpdater.shared` in the application delegate as shown below.
5. Connect a menu item's action to `checkForUpdates(_:)`.
6. Add the public feed settings shown in `Sparkle-Info.plist` to the app's real Info.plist or generated Info properties.

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appUpdater = AppUpdater.shared
}
```

Do not copy placeholder values into a release. Generate a real key with Sparkle's official `generate_keys` tool and use only its public key in the app.
