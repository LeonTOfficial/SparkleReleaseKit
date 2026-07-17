# Changelog

All notable changes to SparkleReleaseKit are documented here. The project follows Semantic Versioning.

## [Unreleased]

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
