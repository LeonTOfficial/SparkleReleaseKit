# SparkleReleaseKit project handoff

This file is the starting point for a new human or coding-agent session. It describes the current project state and prevents SparkleReleaseKit work from being mixed with Battery Panic.

## Repository identity

- Project: SparkleReleaseKit
- Owner: LeonTOfficial
- Repository: https://github.com/LeonTOfficial/SparkleReleaseKit
- Local checkout: `/Users/leontscheschlock/Documents/Codex/2026-07-17/SparkleReleaseKit`
- Default branch: `main`
- Current stable release: `v0.2.0`
- Package language mode: Swift 6
- Minimum supported platform: macOS 13
- License: MIT

Always confirm the live state before editing:

```bash
cd "/Users/leontscheschlock/Documents/Codex/2026-07-17/SparkleReleaseKit"
git fetch --prune
git status --short --branch
git log --oneline --decorate -8
```

## Strict project boundary

SparkleReleaseKit and Battery Panic are independent projects:

- They have separate directories, Git repositories, remotes, histories, releases, CI workflows, source trees, and documentation.
- SparkleReleaseKit must build and test without Battery Panic being present.
- Do not edit, copy generated files into, release, or commit anything in Battery Panic while working on SparkleReleaseKit.
- Battery Panic may be mentioned as project history or used manually as an external integration example, but it is not a dependency.
- Never hard-code a Battery Panic path, bundle identifier, release URL, signing identity, or appcast into SparkleReleaseKit.

The Battery Panic repository is intentionally outside this checkout. Treat it as out of scope unless Leon starts a separate Battery Panic task.

## What exists now

SparkleReleaseKit is a standalone Swift command-line toolkit around the official Sparkle 2 update framework. It does not replace or fork Sparkle.

The package contains:

- `SparkleReleaseKitCore`: project detection, configuration, safe integration, diagnostics, build validation, archive verification, appcast validation, Ed25519 verification, and release staging.
- `SparkleReleaseKitCLI`: the `sparklekit` command-line interface.
- AppKit and SwiftUI reference integrations in `examples/`.
- Human documentation in `docs/`.
- Agent-oriented instructions in `AGENTS.md`, `llms.txt`, and `AI/`.
- A JSON configuration schema in `schemas/`.
- CI, CodeQL, dependency review, secret checks, reusable validation, release packaging, and GitHub Pages workflows in `.github/workflows/`.
- A documentation website in `website/`.

Version 0.2.0 supports explicit `free`, `developer-id`, and capability-aware `auto` release modes. Sparkle EdDSA authentication is required in every mode. A paid Apple Developer membership is optional; Developer ID and notarization are a stronger optional distribution layer.

## Security boundaries

Read `docs/SECURITY_MODEL.md` and `AI/AI_INTEGRATION.md` before changing release, archive, signing, appcast, process-execution, or filesystem code.

Never:

- request, read, log, print, transmit, or commit a private Sparkle EdDSA key;
- commit Apple credentials, `.p8`, `.p12`, passwords, tokens, or signing secrets;
- pass private signing keys as command-line arguments;
- weaken Gatekeeper, Hardened Runtime, App Sandbox, library validation, or signature checks just to make a test pass;
- use an unofficial Sparkle fork;
- use floating GitHub Action tags where the repository requires immutable commit pins;
- publish a release without Leon explicitly requesting publication.

Keep these trust layers distinct in code and documentation:

1. Sparkle EdDSA update authentication.
2. Unsigned or ad-hoc local app signing.
3. Apple Development signing.
4. Developer ID signing.
5. Apple notarization and stapling.

## Baseline verification

Run these before starting a feature and again before reporting completion:

```bash
./scripts/run-tests.sh
swift build -c release
./scripts/check-site.sh
git diff --check
git status --short
```

For CLI smoke coverage:

```bash
./scripts/bootstrap.sh
./scripts/test-cli.sh
./sparklekit version
```

For a real target integration, follow `AI/AI_INTEGRATION.md`. A completion claim requires real `doctor`, `test`, archive verification, appcast validation, and older-to-newer update evidence. File presence alone is not enough.

## Current product direction

Treat `v0.2.0` as the stable baseline. The next planned milestone in `ROADMAP.md` is 0.3, Publication Preview:

- test-feed generation;
- GitHub Release and Pages publication preview;
- optional SBOM and provenance adapters without overstating coverage.

Before implementing a roadmap item:

1. inspect open GitHub issues and pull requests;
2. confirm the requested scope with Leon;
3. create a focused branch from current `origin/main`;
4. preserve compatibility with the documented v0.2 configuration contract;
5. add tests and update human, CLI, schema, and AI documentation together when behavior changes.

Do not start a new milestone merely because it is listed here. The next chat should first ask Leon which SparkleReleaseKit task he wants to pursue, unless his opening message already specifies it.

## Working style for the next chat

- Work only in the SparkleReleaseKit checkout above.
- Read the repository before proposing architecture changes.
- Prefer small, reviewable commits and existing local patterns.
- Preview integration changes before applying them.
- Preserve unrelated user changes in a dirty worktree.
- Use deterministic `--json` output when validating behavior for another coding agent.
- Explain both the human path and the AI-agent path when adding public workflows.
- Keep documentation direct enough that a first-time macOS developer can follow it.

## New-chat opening prompt

The new chat can start with:

```text
Continue SparkleReleaseKit as its own independent project.
Work only in /Users/leontscheschlock/Documents/Codex/2026-07-17/SparkleReleaseKit.
Read AGENTS.md and AI/PROJECT_HANDOFF.md first, verify the current Git and test state,
and do not edit Battery Panic. Ask what SparkleReleaseKit task I want next only if I
have not already given you one.
```

## End-of-session handoff

Before ending a future SparkleReleaseKit session, update this file only when the stable baseline, current milestone, project boundary, or required verification process has materially changed. Record unfinished work in a focused issue or branch, not as ambiguous prose on `main`.
