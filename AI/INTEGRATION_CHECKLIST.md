# Integration checklist

## Discovery

- [ ] Target repository instructions were read.
- [ ] Correct workspace or project was identified.
- [ ] Correct app target and shared scheme were identified.
- [ ] AppKit or SwiftUI lifecycle was confirmed from source.
- [ ] Existing update implementation was searched for.
- [ ] Baseline build or tests passed, or existing failures were recorded.

## Configuration

- [ ] `sparklekit.json` validates against the published schema.
- [ ] Feed URL uses HTTPS.
- [ ] Bundle identifier matches the built app.
- [ ] Sparkle version is supported.
- [ ] Release mode is explicitly `free`, `developer-id`, or `auto`.
- [ ] Sparkle EdDSA authentication remains required in the selected mode.
- [ ] Developer ID and notarization are treated as separate optional Apple trust layers unless explicitly required.
- [ ] Only the public EdDSA key is present.
- [ ] No credential or private key entered model context or source control.

## Integration

- [ ] Dry-run output was reviewed.
- [ ] Integration was applied once.
- [ ] Re-running the dry run reports no unexpected changes.
- [ ] Official Sparkle Swift package is attached to the app target.
- [ ] `AppUpdater.shared` remains alive for the app lifetime.
- [ ] Manual update command is reachable.

## Verification

- [ ] `sparklekit doctor --json` has zero failures.
- [ ] `sparklekit test --json` has zero failures.
- [ ] Unit tests pass.
- [ ] Release configuration builds.
- [ ] ZIP or DMG contains one expected `.app`.
- [ ] Bundle metadata is correct.
- [ ] Main executable contains every configured CPU architecture.
- [ ] Sparkle.framework is embedded.
- [ ] Code signature verifies.
- [ ] Code-signing class matches the selected release mode.
- [ ] Appcast validates and contains one unambiguous Sparkle EdDSA signature.
- [ ] `sparklekit verify-update` authenticates the exact archive bytes.
- [ ] SHA-256 checksum matches the staged archive.
- [ ] `release-manifest.json` records the verified versions, architectures, signing class, and trust state.
- [ ] Requested release version matches `CFBundleShortVersionString` in the archive.
- [ ] Older build discovers and installs the new test update.
- [ ] Repository secret scan is clean.
