# SwiftUI integration

After `sparklekit integrate --apply`, add the official Sparkle package to the app target and ensure `SparkleReleaseKit/AppUpdater.swift` belongs to that target.

Keep the updater alive in the app lifecycle:

```swift
@main
struct MyApp: App {
    @State private var appUpdater = AppUpdater.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    AppUpdater.shared.checkForUpdates()
                }
            }
        }
    }
}
```

If your deployment target cannot use `@State` with this reference type, use a stored property instead:

```swift
private let appUpdater = AppUpdater.shared
```
