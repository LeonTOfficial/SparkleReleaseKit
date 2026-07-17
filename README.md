<div align="center">
  <h1>SparkleReleaseKit</h1>
  <p><strong>Add secure Sparkle updates to a macOS app with GitHub Releases in minutes.</strong></p>
  <p>
    <a href="https://github.com/LeonTOfficial/SparkleReleaseKit/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/LeonTOfficial/SparkleReleaseKit/actions/workflows/ci.yml/badge.svg"></a>
    <a href="https://github.com/LeonTOfficial/SparkleReleaseKit/releases"><img alt="Release" src="https://img.shields.io/github/v/release/LeonTOfficial/SparkleReleaseKit?display_name=tag"></a>
    <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-2ea44f"></a>
    <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
    <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple">
  </p>
</div>

SparkleReleaseKit is a human-friendly and AI-friendly toolkit around [Sparkle 2](https://sparkle-project.org/). It detects an existing Xcode project, creates the updater integration, configures secure update metadata, adds release validation, and explains the two Xcode steps that cannot be changed safely through a public command-line API.

It does **not** replace or fork Sparkle. Sparkle remains the secure update engine; SparkleReleaseKit makes the surrounding setup reproducible and difficult to misconfigure.

## What it does

- Detects `.xcodeproj` and `.xcworkspace` projects.
- Recognizes AppKit and SwiftUI applications.
- Infers the app name, bundle identifier, scheme, `Info.plist`, and GitHub remote.
- Creates one validated `sparklekit.json` configuration.
- Generates a minimal `AppUpdater.swift` for Sparkle 2.9.4.
- Adds `SUFeedURL`, `SUPublicEDKey`, and automatic-update preferences safely.
- Creates a GitHub Actions release-readiness workflow.
- Pins every generated external workflow dependency to an immutable commit SHA.
- Protects private keys, certificates, backups, and release staging files.
- Previews every integration change before writing anything.
- Creates a timestamped backup and restores its own changes if integration fails.
- Verifies ZIP and DMG archives, safe extraction paths, expansion limits, bundle metadata, nested code signatures, Gatekeeper status, and embedded Sparkle.
- Runs Xcode package resolution and a credential-free Release build with `sparklekit test`.
- Validates appcast structure, credential-free HTTPS enclosure URLs, versions, lengths, and exact 64-byte Ed25519 signature fields.
- Stages a signed archive and invokes Sparkle's official `generate_appcast` through `prepare-release`.
- Emits stable JSON from diagnostic commands so coding agents and CI can act on exact results.
- Includes instructions designed for both people and coding agents.

## Ten-minute quick start

Requirements: macOS 13 or later, the latest stable Xcode, Git, and an existing macOS app target.

Download the [latest tested macOS package](https://github.com/LeonTOfficial/SparkleReleaseKit/releases/latest/download/SparkleReleaseKit-macos.zip), extract it, open Terminal in the extracted `SparkleReleaseKit` folder, and run:

```bash
./install.sh
sparklekit version
```

The release also contains a SHA-256 checksum and a GitHub artifact attestation. Until the CLI itself is Developer-ID signed and notarized, macOS may quarantine a downloaded binary. The source-build route below is the most reliable fallback and creates the executable locally:

```bash
git clone https://github.com/LeonTOfficial/SparkleReleaseKit.git
cd SparkleReleaseKit
./scripts/bootstrap.sh
./scripts/install.sh
./sparklekit setup "/path/to/YourApp"
```

Generate your Sparkle EdDSA key once using Sparkle's official `generate_keys` tool. Keep the private key in Keychain and put only the printed public key in your app's `sparklekit.json`:

```json
"publicEDKey": "YOUR_PUBLIC_ED25519_KEY"
```

Preview and apply the integration:

```bash
./sparklekit integrate "/path/to/YourApp"
./sparklekit integrate "/path/to/YourApp" --apply
./sparklekit doctor "/path/to/YourApp"
./sparklekit test "/path/to/YourApp"
```

Finish the two clearly documented Xcode steps in `YourApp/SparkleReleaseKit/INTEGRATION.md`:

1. Add `https://github.com/sparkle-project/Sparkle` with Swift Package Manager.
2. Keep `AppUpdater.shared` alive from application startup.

That is the complete app-side integration. Reference implementations for both lifecycles are available in [`examples/`](examples/README.md).

## What remains deliberately manual

SparkleReleaseKit removes repetitive setup, but it does not pretend that every Xcode and signing decision can be automated safely. A developer or coding agent must still:

1. Attach the official Sparkle package product to the correct application target.
2. Connect the generated updater to the app lifecycle and expose **Check for Updates...**.
3. Own Developer ID signing, Hardened Runtime, and Apple notarization credentials.
4. Test one real older build updating to the new build before a production rollout.

Those boundaries are part of the security design, not missing polish.

## Safe by default

`sparklekit integrate` is a dry run. It only writes when `--apply` is supplied. Before modifying an existing file, SparkleReleaseKit copies it into `.sparklekit/backups/<timestamp>/`. Private signing material is never accepted as configuration and common private-key formats are automatically ignored by Git.

The CLI rejects unknown or duplicated options instead of silently guessing. Archive verification rejects path traversal, escaping symbolic links, unreasonable expansion sizes, malformed metadata, and mismatched bundle identifiers before a feed can be staged.

For production distribution, use Developer ID signing, Hardened Runtime, HTTPS, Sparkle EdDSA signatures, and Apple notarization. See [Security](docs/SECURITY_MODEL.md).

## Commands

```text
sparklekit setup [project-path] [options]
sparklekit integrate [project-path] [--apply]
sparklekit doctor [project-path] [--json]
sparklekit test [project-path] [--json]
sparklekit verify <archive.zip|archive.dmg> [--project path] [--json]
sparklekit validate-feed <appcast.xml> [--json]
sparklekit prepare-release <archive> --version X.Y.Z [options]
sparklekit version
```

Install the CLI from a source checkout for your user account:

```bash
./scripts/install.sh
```

The default location is `~/.local/bin/sparklekit`; no administrator password is needed.

## Prepare a release safely

Build, Developer-ID sign, and notarize your app with your existing Xcode release process first. Then let SparkleReleaseKit verify the exact update ZIP and create an isolated signed appcast stage:

```bash
sparklekit prepare-release "/path/to/MyApp-1.2.0.zip" \
  --project "/path/to/MyApp" \
  --version 1.2.0 \
  --notes "/path/to/release-notes.md" \
  --generate-appcast "/path/to/Sparkle/bin/generate_appcast"
```

The official Sparkle tool reads the private key from macOS Keychain. SparkleReleaseKit never accepts that private key in `sparklekit.json`, command output, or a generated file. The prepared archive, appcast, and notes are placed in `.sparklekit/releases/v1.2.0/` for review; publication is deliberately separate and explicit.

## For coding agents

Give your coding assistant this repository and the target macOS repository, then use:

```text
Integrate SparkleReleaseKit into this macOS app.
Read AGENTS.md and AI/AI_INTEGRATION.md before editing anything.
Run sparklekit setup and doctor, preview integration before applying it,
never expose private signing material, use --json for deterministic checks,
and verify the final Xcode build and archive.
```

The repository contains `AGENTS.md`, `llms.txt`, a JSON Schema, deterministic commands, expected outputs, and a completion checklist. See [AI integration](AI/AI_INTEGRATION.md).

## Documentation

- [Quick start](docs/QUICKSTART.md)
- [CLI reference](docs/CLI_REFERENCE.md)
- [AppKit integration](docs/APPKIT.md)
- [SwiftUI integration](docs/SWIFTUI.md)
- [Release process](docs/RELEASE_PROCESS.md)
- [Security model](docs/SECURITY_MODEL.md)
- [Update key management](docs/KEY_MANAGEMENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Reference integrations](examples/README.md)
- [Roadmap](ROADMAP.md)

## Current scope

Version 0.1 focuses on regular macOS `.app` bundles built by Xcode and ZIP or DMG distribution. Package installers, external bundles, and unattended Developer ID credential provisioning are intentionally outside the initial scope. Those workflows need different authorization and should not be guessed automatically.

## Credits

Built by [LeonTOfficial](https://github.com/LeonTOfficial), based on lessons learned while building [Battery Panic](https://github.com/LeonTOfficial/BatteryPanic). SparkleReleaseKit uses the official Sparkle project; it is not affiliated with or endorsed by the Sparkle maintainers.

Released under the [MIT License](LICENSE).
