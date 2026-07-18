# Free and independent distribution

You do **not** need a paid Apple Developer Program membership to use SparkleReleaseKit or to ship a Sparkle update feed.

Free mode separates two different jobs:

- Sparkle Ed25519/EdDSA signing authenticates the downloaded update archive.
- An ad-hoc app signature gives the local bundle a consistent structural signature.

Neither one makes the app Apple-notarized. macOS may show a first-launch Gatekeeper warning, and users may need to approve the app once in **System Settings > Privacy & Security**.

## Configuration

```json
"distribution": {
  "installer": "dmg",
  "updateArchive": "zip",
  "releaseMode": "free",
  "requireSparkleSignature": true,
  "requireDeveloperID": false,
  "requireNotarization": false,
  "allowAdHocSigning": true,
  "expectedArchitectures": ["arm64", "x86_64"]
}
```

Create this policy directly during setup:

```bash
sparklekit setup "/path/to/MyApp" \
  --release-mode free \
  --architectures arm64,x86_64
```

## Release flow

1. Build a Release app with Xcode.
2. Give nested code and the outer app valid signatures. For a free build, Xcode or `codesign --sign -` can create ad-hoc signatures; sign nested code before the outer app.
3. Package exactly one app in the update ZIP.
4. Run `sparklekit verify` in free mode.
5. Run `sparklekit prepare-release` with Sparkle's official `generate_appcast` tool.
6. Upload the staged ZIP and publish the staged `appcast.xml` over HTTPS.
7. Test an older installed build updating to the new build.

```bash
sparklekit verify MyApp-1.2.0.zip \
  --project /path/to/MyApp \
  --release-mode free \
  --allow-ad-hoc-signing

sparklekit prepare-release MyApp-1.2.0.zip \
  --project /path/to/MyApp \
  --version 1.2.0 \
  --release-mode free \
  --generate-appcast /path/to/Sparkle/bin/generate_appcast
```

The release stage contains the archive, appcast, notes, a SHA-256 checksum, and `release-manifest.json`. Preparation fails if the generated EdDSA signature does not authenticate the exact staged archive.

## Honest limitations

- Gatekeeper does not treat ad-hoc signing as a trusted Developer ID identity.
- The first download can require manual approval.
- Do not tell users to disable Gatekeeper globally.
- An unsigned app can be inspected in free mode with a warning, but a consistent ad-hoc signature is preferred.
- Sparkle signing protects update authenticity; it does not remove macOS first-launch policy.

For a warning-free Apple-verified path, use [Developer ID distribution](DEVELOPER_ID_DISTRIBUTION.md).
