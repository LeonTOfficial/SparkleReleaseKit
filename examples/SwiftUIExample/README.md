# SwiftUI example

1. Add `https://github.com/sparkle-project/Sparkle` through Xcode's package dependency UI.
2. Link the `Sparkle` product to the macOS app target.
3. Add the two Swift files in this directory to that target.
4. Add the public feed settings shown in `Sparkle-Info.plist` to the app's real Info.plist or generated Info properties.

`AppUpdater.shared` owns `SPUStandardUpdaterController`. The `@State` property in `ExampleApp` keeps that owner alive, and the command calls the same shared instance.

Do not copy placeholder values into a release. Generate a real key with Sparkle's official `generate_keys` tool and use only its public key in the app.
