# AI integration protocol

This document is the authoritative procedure for a coding agent integrating SparkleReleaseKit into an existing macOS application.

## Objective

Produce a buildable, secure Sparkle 2 integration while preserving the target repository's architecture, user changes, signing settings, and release process.

## Inputs

- Absolute path to the target repository.
- The application target and shared scheme.
- GitHub owner and repository.
- Public Sparkle EdDSA key. The private key must never enter model context.
- Explicit distribution choice: `free`, `developer-id`, or `auto`.
- Optional Developer ID and notarization configuration supplied through secure CI secrets only when the owner selects that route.

## Procedure

1. Read the target repository's own `AGENTS.md` and contributor instructions.
2. Inspect all `.xcodeproj`, `.xcworkspace`, shared schemes, app lifecycle files, Info.plists, entitlements, and existing update code.
3. Build or test the unchanged target once to establish a baseline.
4. Ask which release path the owner wants. Default to `free` when no paid Apple membership is available; never equate this choice with disabling Sparkle EdDSA.
5. Run `sparklekit quickstart <target-path> --non-interactive --release-mode <mode>` with explicit metadata flags.
6. Review `sparklekit.json`. Correct detection mistakes before continuing.
7. Run `sparklekit integrate <target-path>` without `--apply`.
8. Confirm every proposed path belongs to the intended target repository.
9. Run `sparklekit integrate <target-path> --apply`.
10. Add the official Sparkle package and `Sparkle` product to the app target.
11. Add the generated updater source to the app target when necessary.
12. Keep `AppUpdater.shared` alive from application startup.
13. Add or connect a **Check for Updates...** command.
14. Run `sparklekit doctor <target-path> --json` and resolve every `failure` result.
15. After explicit approval to execute target-project build scripts and package plug-ins, run `sparklekit test <target-path> --allow-project-execution --json`. Add `--allow-network` only with separate approval for automatic Xcode package resolution. Project execution itself remains a broad trust decision, not a network sandbox.
16. Build an ad-hoc signed artifact for free mode, or a Developer-ID signed and notarized artifact for Developer ID mode. Run `sparklekit verify --json` with the same mode.
17. Run `sparklekit prepare-release` with the official `generate_appcast` executable. Do not provide private key material to the agent.
18. Run `sparklekit validate-feed <appcast.xml> --json` and `sparklekit verify-update`.
19. Check the generated SHA-256 file and `release-manifest.json`.
20. Test updating from an older real build to the new test build through an isolated test appcast.
21. For an existing integration, run `sparklekit project upgrade --json`
    before `--apply`; stop on every conflict and preserve manual edits.
22. Treat `sparklekit update install` as a separate explicit CLI maintenance
    action. It never updates the app or its Sparkle dependency.

## Non-interactive example

```bash
sparklekit quickstart "/workspace/MyApp" \
  --non-interactive \
  --owner ExampleDeveloper \
  --repo MyApp \
  --app-name "My App" \
  --bundle-id com.example.MyApp \
  --scheme "My App" \
  --release-mode free \
  --public-key "$SPARKLE_PUBLIC_KEY"

sparklekit integrate "/workspace/MyApp"
sparklekit integrate "/workspace/MyApp" --apply
sparklekit doctor "/workspace/MyApp" --json
sparklekit test "/workspace/MyApp" --allow-project-execution --json
```

`SPARKLE_PUBLIC_KEY` must contain only the public key. Never request, echo, log, read, or transmit the private key. Sparkle EdDSA release signing is required in every mode; instruct the human to prepare that private key in macOS Keychain and run the explicitly reviewed command themselves. Developer ID credentials are optional and must not be requested in free mode.

Interactive prompts, terminal progress, and human-readable text must never be parsed by an agent. Use `--non-interactive --json`; standard output then contains exactly one JSON envelope. Project execution and network access remain separate approvals.

## Trust-layer rule

Never describe Developer ID as the Sparkle update signature. Report these independently:

1. Sparkle EdDSA archive authentication.
2. Local/ad-hoc or unsigned app state.
3. Apple Development state.
4. Developer ID state.
5. Apple notarization and staple state.

## Expected generated files

- `sparklekit.json`
- `SparkleReleaseKit/AppUpdater.swift`
- `SparkleReleaseKit/INTEGRATION.md`
- `.github/workflows/sparkle-release.yml`
- `release-notes/next.md`
- `.sparklekit/manifest.json`

## Completion report

Use [VERIFY_RESULT.md](VERIFY_RESULT.md). Do not claim completion from file presence alone. Include the exact build, test, doctor, archive verification, and update-path results.
