# Changelog

All notable changes to SparkleReleaseKit are documented here. The project follows Semantic Versioning.

## [0.2.0] - 2026-07-18

### Added

- Explicit `free`, `developer-id`, and `auto` release modes without making a paid Apple Developer membership mandatory.
- Cryptographic Ed25519 verification of each staged update archive against its appcast enclosure.
- CPU architecture, signing-class, Hardened Runtime, Apple Team ID, Gatekeeper, and notarization-staple diagnostics.
- SHA-256 checksum files and deterministic `release-manifest.json` output.
- `verify-update` command for independent Sparkle signature verification.
- Schema v2 with safe schema v1 migration.
- Dedicated free distribution, Developer ID, Gatekeeper, and update-signing guides.

### Changed

- CLI version is now 0.2.0.
- Generated validation workflows use the reviewed v0.1.1 immutable commit.
- Release preparation now copies the archive into an isolated transaction before inspecting, signing, checksumming, and publishing it.
- Process output capture preserves useful beginning and ending diagnostics while bounding memory use for exceptionally large tool logs.
- Website reveal animations now degrade safely so documentation stays visible when JavaScript is blocked or unavailable.

### Security

- Re-checks the staged archive size and SHA-256 digest after EdDSA verification to detect changes during release preparation.
- Keeps temporary process output in a user-private directory and bounds data loaded back into memory.

## [0.1.1] - 2026-07-17

### Security

- Redacted suspicious tracked-file paths and Git command output from `doctor` diagnostics so secret scans report the problem without echoing potentially sensitive metadata.
- Added regression coverage that guarantees suspicious filenames are omitted from human-readable diagnostics.

## [0.1.0] - 2026-07-17

### Added

- Swift 6 command-line toolkit for Xcode-backed project detection, strict configuration, integration, diagnostics, Release builds, and archive verification.
- Transactional dry-run and apply workflow with timestamped backups.
- Symlink-aware path containment and rollback coverage.
- ZIP traversal, expansion-limit, extracted-link, nested-signature, and Gatekeeper checks.
- Strict control-character, file-count, file-size, hidden-app, and DMG Applications-link handling.
- AppKit and SwiftUI updater templates for Sparkle 2.9.4.
- Appcast validation and secure release staging through Sparkle's official `generate_appcast` tool.
- Stable JSON reports and documented command exit codes for coding agents and CI.
- Universal arm64/x86_64 CLI packaging and build provenance attestation.
- Ad-hoc package signing and post-install signature verification for the public CLI artifact.
- Reference AppKit and SwiftUI source integrations plus a responsive documentation website.
- Machine-readable JSON Schema, `AGENTS.md`, `llms.txt`, and AI integration protocol.
- GitHub Actions, CodeQL, dependency review, release-readiness checks, and secret guards.
- Immutable full-commit pins for both bundled and generated GitHub Actions dependencies.
- Strict CLI option handling and exact Ed25519 key and appcast-signature validation.
- Bounded configuration and project-file reads plus explicit-only execution of the reviewed `generate_appcast` signing tool.
- English documentation for setup, security, release delivery, and troubleshooting.
