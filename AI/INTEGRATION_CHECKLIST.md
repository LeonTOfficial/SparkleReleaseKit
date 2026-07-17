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
- [ ] Sparkle.framework is embedded.
- [ ] Code signature verifies.
- [ ] Appcast validates and contains a Sparkle EdDSA signature.
- [ ] Requested release version matches `CFBundleShortVersionString` in the archive.
- [ ] Older build discovers and installs the new test update.
- [ ] Repository secret scan is clean.
