# Quick start

This guide adds Sparkle updates to a regular macOS `.app` built with Xcode.

## Before you begin

You need macOS 13 or later, a current stable Xcode installation, Git, a shared app scheme, and a GitHub repository. A paid Apple Developer membership is optional: use free mode without it, or Developer ID mode for Apple's verified route.

## Install SparkleReleaseKit

The tested release archive is the shortest route:

1. Download [SparkleReleaseKit-macos.zip](https://github.com/LeonTOfficial/SparkleReleaseKit/releases/latest/download/SparkleReleaseKit-macos.zip).
2. Extract it and open Terminal in the extracted `SparkleReleaseKit` folder.
3. Run `./install.sh`, then `sparklekit version`.

The installer writes only to `~/.local/bin` by default and does not request administrator access. A checksum and GitHub artifact attestation accompany every release. If macOS quarantines the currently non-notarized CLI binary, build it locally from source instead:

```bash
git clone https://github.com/LeonTOfficial/SparkleReleaseKit.git
cd SparkleReleaseKit
./scripts/bootstrap.sh
./scripts/install.sh
```

Restart Terminal if `~/.local/bin` was newly added to your `PATH`.

## Detect and configure the app

```bash
sparklekit setup "/path/to/YourApp" --release-mode free
```

Inspect the generated `sparklekit.json`. The configuration contains public project metadata only.

## Generate the update key

Use Sparkle's official `generate_keys` executable once. It stores the private EdDSA key in your login Keychain and prints the public key. Add only the printed public key to `updates.publicEDKey`.

Do not export the private key unless a secured CI workflow requires it. Never commit or paste the private key into an issue, chat, prompt, log, or configuration file.

## Preview and apply

```bash
sparklekit integrate "/path/to/YourApp"
sparklekit integrate "/path/to/YourApp" --apply
```

Open the generated `SparkleReleaseKit/INTEGRATION.md` inside your app repository and complete its two Xcode steps.

## Verify

```bash
sparklekit doctor "/path/to/YourApp"
sparklekit test "/path/to/YourApp"
```

Then build the app in Release configuration. After packaging a real release:

```bash
sparklekit verify "/path/to/YourApp.zip" --project "/path/to/YourApp"
```

Prepare the signed appcast stage with Sparkle's official tool:

```bash
sparklekit prepare-release "/path/to/YourApp-1.2.0.zip" \
  --project "/path/to/YourApp" \
  --version 1.2.0 \
  --release-mode free \
  --notes "/path/to/release-notes.md" \
  --generate-appcast "/path/to/Sparkle/bin/generate_appcast"
```

Review `.sparklekit/releases/v1.2.0/`. It contains the update archive, appcast, notes, checksum, and release manifest. Then test a real update from an older version using a separate test feed before publishing the production feed.

Read [Free distribution](FREE_DISTRIBUTION.md) or [Developer ID distribution](DEVELOPER_ID_DISTRIBUTION.md) for the complete path you selected.

All diagnostic commands support `--json`. Coding agents and CI should prefer that mode because it provides stable severity, title, detail, and remediation fields.
