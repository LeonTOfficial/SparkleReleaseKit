# Instructions for coding agents

This repository is an integration toolkit for secure macOS software updates. Treat update signing as a security boundary.

## Required workflow

1. Read `README.md`, `AI/AI_INTEGRATION.md`, and `docs/SECURITY_MODEL.md`.
2. Inspect the target repository before selecting a project, workspace, scheme, lifecycle, or plist path.
3. Run `sparklekit setup <target>` only after inspection.
4. Run `sparklekit integrate <target>` without `--apply` and review every proposed path.
5. Never place private EdDSA keys, `.p8` keys, `.p12` certificates, Apple passwords, or tokens in source files, configuration, logs, prompts, issues, or commits.
6. Apply changes only with `sparklekit integrate <target> --apply`.
7. Add the official Sparkle package to the application target. Do not use an unofficial fork.
8. Keep the generated `AppUpdater.shared` alive for the application lifetime.
9. Run `sparklekit doctor --json`, `sparklekit test --json`, and the target's own tests.
10. Verify a real archive with `sparklekit verify --json` before claiming completion.
11. Validate the generated appcast with `sparklekit validate-feed --json`.

## Editing boundaries

- Do not rewrite an entire Xcode project file to add one dependency.
- Preserve unrelated user changes and existing signing settings.
- Do not weaken Hardened Runtime, App Sandbox, library validation, or Gatekeeper checks merely to make a build pass.
- Do not use `codesign --deep` to sign a release.
- Do not publish a release unless the user explicitly requests publication.
- Never pass a private update key in a command argument; use macOS Keychain or protected CI standard input exactly as documented by Sparkle.
- Prefer HTTPS and the stable Sparkle version declared in `SparkleKitConfiguration.supportedSparkleVersion`.

## Completion evidence

Completion requires all of the following:

- `sparklekit doctor` has no failures.
- The app builds in Release configuration.
- `Sparkle.framework` is embedded and signed.
- `SUFeedURL` is HTTPS and reachable.
- `SUPublicEDKey` contains only the public EdDSA key.
- The appcast and update archive are signed by Sparkle.
- An older real app build can discover a newer test build.
- No signing secrets are tracked by Git.
