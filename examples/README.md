# Reference integrations

These small examples show the final application-side shape after SparkleReleaseKit has generated `AppUpdater.swift` and the official Sparkle package has been added to the app target.

- [SwiftUI lifecycle](SwiftUIExample/README.md)
- [AppKit lifecycle](AppKitExample/README.md)

They are intentionally source-level references rather than fake one-size-fits-all Xcode projects. Run `sparklekit setup` against your real project so the tool can detect its scheme, plist strategy, bundle identifier, and repository.

Both examples keep the updater alive for the application lifetime and expose **Check for Updates...** without duplicating Sparkle logic.
