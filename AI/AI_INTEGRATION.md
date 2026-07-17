# AI integration protocol

This document is the authoritative procedure for a coding agent integrating SparkleReleaseKit into an existing macOS application.

## Objective

Produce a buildable, secure Sparkle 2 integration while preserving the target repository's architecture, user changes, signing settings, and release process.

## Inputs

- Absolute path to the target repository.
- The application target and shared scheme.
- GitHub owner and repository.
- Public Sparkle EdDSA key. The private key must never enter model context.
- Optional Developer ID and notarization configuration supplied through secure CI secrets.

## Procedure

1. Read the target repository's own `AGENTS.md` and contributor instructions.
2. Inspect all `.xcodeproj`, `.xcworkspace`, shared schemes, app lifecycle files, Info.plists, entitlements, and existing update code.
3. Build or test the unchanged target once to establish a baseline.
4. Run `sparklekit setup <target-path>` with explicit flags when non-interactive.
5. Review `sparklekit.json`. Correct detection mistakes before continuing.
6. Run `sparklekit integrate <target-path>` without `--apply`.
7. Confirm every proposed path belongs to the intended target repository.
8. Run `sparklekit integrate <target-path> --apply`.
9. Add the official Sparkle package and `Sparkle` product to the app target.
10. Add the generated updater source to the app target when necessary.
11. Keep `AppUpdater.shared` alive from application startup.
12. Add or connect a **Check for Updates...** command.
13. Run `sparklekit doctor <target-path> --json` and resolve every `failure` result.
14. Run `sparklekit test <target-path> --json`.
15. Build a real Developer-ID signed and notarized ZIP or DMG and run `sparklekit verify --json`.
16. Run `sparklekit prepare-release` with the official `generate_appcast` executable. Do not provide private key material to the agent.
17. Run `sparklekit validate-feed <appcast.xml> --json`.
18. Test updating from an older real build to the new test build through an isolated test appcast.

## Non-interactive example

```bash
sparklekit setup "/workspace/MyApp" \
  --owner ExampleDeveloper \
  --repo MyApp \
  --app-name "My App" \
  --bundle-id com.example.MyApp \
  --scheme "My App" \
  --public-key "$SPARKLE_PUBLIC_KEY"

sparklekit integrate "/workspace/MyApp"
sparklekit integrate "/workspace/MyApp" --apply
sparklekit doctor "/workspace/MyApp" --json
sparklekit test "/workspace/MyApp" --json
```

`SPARKLE_PUBLIC_KEY` must contain only the public key. Never request, echo, log, read, or transmit the private key. If release signing is required, instruct the human to prepare the private key in macOS Keychain and run the explicitly reviewed command themselves.

## Expected generated files

- `sparklekit.json`
- `SparkleReleaseKit/AppUpdater.swift`
- `SparkleReleaseKit/INTEGRATION.md`
- `.github/workflows/sparkle-release.yml`
- `release-notes/next.md`
- `.sparklekit/manifest.json`

## Completion report

Use [VERIFY_RESULT.md](VERIFY_RESULT.md). Do not claim completion from file presence alone. Include the exact build, test, doctor, archive verification, and update-path results.
