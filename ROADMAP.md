# Roadmap

## 0.1 - Foundation

- Project detection for Xcode projects and workspaces.
- Safe configuration and transactional integration.
- AppKit and SwiftUI guidance.
- Release archive verification.
- Credential-free Release build validation.
- Appcast validation and official `generate_appcast` release staging.
- Stable JSON output and documented exit codes for automation.
- Universal CLI release, documentation website, and source-level reference integrations.
- Human and coding-agent documentation.

## 0.2 - Inclusive release verification

- Explicit `free`, `developer-id`, and `auto` distribution policies.
- Real Ed25519 archive verification after appcast generation.
- Architecture, signing-class, Hardened Runtime, Team ID, Gatekeeper, and staple checks.
- SHA-256 checksum and deterministic release manifest generation.
- Schema v1 migration and schema v2 policy contract.

## 0.3 - Guided operation and publication preview

- Beginner-friendly guided quickstart and deterministic progress.
- Stable diagnostics, repair previews, and versioned JSON envelopes.
- GitHub Release and Pages publication preview without remote writes.

## 0.4 - Secure maintenance and distribution

- Centralized `generate_appcast` trust policy with identity and SHA-256 pins.
- Signed, bounded, atomic CLI self-update with verified rollback.
- Plan-first managed project migration with conflicts, diffs, and rollback.
- Hardened process-tree termination and explicit termination results.
- Protected release metadata signing, optional Developer ID notarized DMG, and provenance.
- Synthetic contract fixture lifecycle for app release, migration, and CLI update.

## Gates before 0.5 adapters

- Split the large CLI router into typed command handlers, a declarative option
  schema, injected services, and separate human/JSON renderers without changing
  syntax, diagnostic IDs, exit codes, or JSON.
- Add committed minimal AppKit and SwiftUI Xcode fixtures using official Sparkle
  2.9.5, real targets, shared schemes, target membership, and lifecycle wiring.
- Run an older-to-newer visible Sparkle update over isolated local HTTPS with
  ephemeral test keys and certificates. Cover sandboxed and non-sandboxed apps,
  invalid signatures, wrong bundle/version, cancellation, and rollback.
- Add a real macOS 13 VM or hardware canary for startup, CLI contracts,
  resources, installation, and self-update; hosted macOS 26 CI alone is not
  evidence for the oldest supported runtime.
- Keep `SparkleReleaseKitCore` explicitly unstable unless DocC, examples,
  migration guidance, and an API-diff gate are introduced.

## 0.5 - Project adapters

- Tuist adapter.
- XcodeGen adapter.
- Multi-target and beta-channel support.
- Real sandboxed and non-sandboxed runtime update fixtures.
- Temporary local HTTPS feed harness for full Sparkle UI installation tests.

## 0.7 - Distribution expansion

- Homebrew tap.
- Interactive setup UI and polished documentation website.

## 1.0 - Stable contract

- Stable configuration schema and migration guarantees.
- Reproducible release workflow.
- End-to-end fixtures for AppKit, SwiftUI, sandboxed, and non-sandboxed apps.
- Documented key rotation, phased rollout, and recovery procedures.
- No paid Apple membership requirement for the stable core workflow.
