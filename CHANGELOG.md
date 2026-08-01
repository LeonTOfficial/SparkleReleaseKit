# Changelog

All notable changes to SparkleReleaseKit are documented here. The project follows Semantic Versioning.

## [0.4.0] - 2026-08-01

### Added

- Central `GenerateAppcastTrustPolicy` with canonical paths, regular-file and executable checks, trusted ownership and parent permissions, strict code-signature inspection, signing identifier, Team ID, designated requirement, SHA-256 allowlists, path-source diagnostics, and CI environment opt-in.
- Signed CLI self-update commands: `update check`, explicit `update install`, verified `update rollback`, local manifest verification, stable JSON, downgrade protection, bounded HTTPS transport, safe archive extraction, atomic activation, and automatic transaction rollback.
- Optional non-blocking update hints limited to once per 24 hours, local preference controls, and a documented no-telemetry contract.
- `project upgrade` preview/apply workflow with schema v4 management metadata, original template hashes, bounded redacted diffs, manual-edit conflicts, backups, idempotency, symlink containment, and full rollback.
- Explicit process termination reason and signal metadata, configurable output retention, and reliable descendant-process termination on timeout.
- Protected release-environment manifest signing, build metadata, optional Developer ID and Hardened Runtime signing, notarized and stapled DMG generation, Gatekeeper checks, and expanded provenance attestations.
- Real end-to-end maintenance fixture covering old and new app releases, Sparkle signatures, tampering, policy modes, interrupted staging, project migration, CLI update, and rollback.
- Dedicated installation, CLI update, and managed-project migration guides.

### Changed

- Configuration schema advances to v4 while schemas v1 through v3 continue to load with controlled defaults.
- The release manifest records the exact trusted `generate_appcast` digest and signing identifier.
- `ProcessRunner` preserves its bounded file-backed output capture while callers can choose a smaller hard retained-output limit.
- CLI and generated metadata report version 0.4.0; Swift 6 mode, macOS 13 minimum, and Sparkle 2.9.4 compatibility remain unchanged.

### Security

- The CLI update private key exists only in the GitHub `release` environment; clients embed only its dedicated public trust root.
- Downloaded CLI packages are never executed before signed-manifest, length, SHA-256, archive-tree, and strict code-signature verification.
- CLI rollback references must remain inside private managed storage, match strict semantic versions, and retain a safe resource-bundle tree.
- Project migrations reject conflicting or duplicate ownership metadata, refuse path-only legacy ownership as overwrite authority, redact sensitive diff lines, and never delete unknown project files.
- `generate_appcast` receives a minimal environment without ambient GitHub, cloud, SSH-agent, or unrelated CI credentials.

## [0.3.0] - 2026-07-26

### Added

- Beginner-friendly `quickstart` wizard with automatic TTY detection, grouped project review, numbered ambiguity resolution, Use/Edit/Cancel decisions, and same-session preview and apply.
- Reusable progress reporting with elapsed time, pass/warn/fail/skipped states, TTY spinners, plain-log heartbeats, `NO_COLOR` support, and bounded sanitized errors.
- Stable `SRK` diagnostic identifiers, `sparklekit explain`, deterministic repair previews through `doctor --fix`, and transactional `doctor --fix --apply`.
- Versioned CLI JSON envelopes and a published output schema for coding agents and CI.
- Read-only `publish preview` planning for release assets, permissions, and intended remote writes.

### Changed

- `doctor`, `test`, `verify`, `prepare-release`, and `publish preview` now expose visible progress in human mode while JSON output remains exactly one document.
- Target-project execution and automatic Xcode package resolution are separate explicit permissions; passive inspection remains the default.
- Project detection, path resolution, process timeouts, output bounds, configuration migration, and generated integration guidance now produce more deterministic diagnostics.
- Release verification now inspects immutable archive snapshots, nested signatures, Hardened Runtime, Library Validation, architecture, notarization policy, and deliberate unsigned-release exceptions more precisely.
- GitHub workflows validate manifests and CLI contracts more thoroughly and retain immutable action references.

### Security

- Integration writes revalidate snapshots, enforce managed-file ownership, serialize concurrent applies, create backups, and roll back touched files after a failed transaction.
- Terminal and diagnostic rendering neutralize control and bidirectional characters and truncate untrusted output.
- Publication previews perform no network request or remote write, and private signing keys remain outside configuration, prompts, logs, and JSON.

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
