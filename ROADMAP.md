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

## 0.3 - Publication preview

- Test-feed generation.
- GitHub Release and Pages publication preview.
- Optional SBOM and provenance adapters without claiming incomplete coverage.

## 0.4 - Distribution test matrix

- End-to-end fixture applications for free and Developer ID release paths.
- Automated older-to-newer update tests against a temporary HTTPS feed.
- Sandboxed and non-sandboxed application coverage.

## 0.5 - Project adapters

- Tuist adapter.
- XcodeGen adapter.
- Multi-target and beta-channel support.
- Local migration assistant for existing Sparkle integrations.

## 0.7 - Distribution expansion

- Homebrew tap.
- Interactive setup UI and polished documentation website.

## 1.0 - Stable contract

- Stable configuration schema and migration guarantees.
- Reproducible release workflow.
- End-to-end fixtures for AppKit, SwiftUI, sandboxed, and non-sandboxed apps.
- Documented key rotation, phased rollout, and recovery procedures.
- No paid Apple membership requirement for the stable core workflow.
