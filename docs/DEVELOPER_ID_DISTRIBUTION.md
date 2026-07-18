# Developer ID distribution

Developer ID mode is the optional Apple-verified route for teams with a paid Apple Developer Program membership. It is **not** required for Sparkle EdDSA signing or for SparkleReleaseKit itself.

## What this mode requires

- A `Developer ID Application` signature on the app and nested code.
- Hardened Runtime.
- A successful Gatekeeper assessment.
- A valid stapled notarization ticket.
- Sparkle EdDSA signing of the update archive.
- HTTPS feed and download URLs.

```json
"distribution": {
  "installer": "dmg",
  "updateArchive": "zip",
  "releaseMode": "developer-id",
  "requireSparkleSignature": true,
  "requireDeveloperID": true,
  "requireNotarization": true,
  "allowAdHocSigning": false,
  "expectedArchitectures": ["arm64", "x86_64"],
  "expectedTeamIdentifier": "ABCDE12345"
}
```

## Release flow

1. Archive the app using your reviewed Xcode release configuration.
2. Sign nested code in the correct bundle order, then sign the outer app with `Developer ID Application` and Hardened Runtime.
3. Submit the final distributable to Apple with `xcrun notarytool`.
4. Inspect Apple's result and log.
5. Staple the accepted ticket before creating the final update ZIP or DMG.
6. Verify the package:

```bash
sparklekit verify MyApp-1.2.0.zip \
  --project /path/to/MyApp \
  --release-mode developer-id \
  --require-developer-id \
  --require-notarization
```

7. Create and cryptographically verify the Sparkle appcast:

```bash
sparklekit prepare-release MyApp-1.2.0.zip \
  --project /path/to/MyApp \
  --version 1.2.0 \
  --release-mode developer-id \
  --generate-appcast /path/to/Sparkle/bin/generate_appcast
```

SparkleReleaseKit does not request certificates, upload credentials to Apple, choose a signing identity, or submit software silently. Those are privileged release-owner decisions.

## Auto mode

`auto` inspects the artifact and reports the effective path. A complete Developer ID + notarization chain is reported as `developer-id`; otherwise it is reported as `free`. Auto mode never acquires credentials or submits to Apple.
