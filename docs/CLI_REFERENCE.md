# CLI reference

SparkleReleaseKit commands are intentionally non-destructive unless an explicit apply or release-staging flag is present. Unknown, duplicated, and incomplete options are rejected instead of guessed.

## Common behavior

- Run commands from any directory by passing the target project path explicitly.
- `quickstart` enters guided mode automatically when standard input is a terminal.
- Use `--interactive` to require the wizard or `--non-interactive` to guarantee that no prompt is read.
- Use `--json` for deterministic automation output where the command supports it.
- JSON standard output is exactly one versioned document, with no prompts, spinners, or progress lines.
- Interactive write confirmations default to No. Numbered ambiguity choices always include Cancel.
- Terminal progress uses a spinner; redirected output uses stable heartbeat lines without control characters.
- Set `NO_COLOR` to disable color capability.
- Paths printed for reuse in a shell are safely quoted.
- Standard input is disconnected from child tools so automation cannot pause on an unexpected password prompt.
- Private update keys are never valid configuration values or CLI arguments.

## Commands

| Command | Purpose | Writes files? |
| --- | --- | --- |
| `sparklekit quickstart [project]` | Guide detection, grouped review, configuration, preview, optional apply, and passive doctor checks. | Only after an interactive confirmation or non-interactive `--apply`. |
| `sparklekit setup [project]` | Lower-level field-by-field setup and automation entry point. | Only with `--apply`. |
| `sparklekit integrate [project]` | Preview generated integration changes. | No. |
| `sparklekit integrate [project] --apply` | Apply the preview with backups and rollback. | Yes. |
| `sparklekit doctor [project]` | Explain configuration and integration problems. | No. |
| `sparklekit doctor [project] --fix` | Preview deterministic repairs. | No. |
| `sparklekit doctor [project] --fix --apply` | Apply deterministic repairs transactionally. | Yes. |
| `sparklekit test [project]` | Run doctor, package resolution, and a credential-free Release build. | Only temporary derived data outside the project. |
| `sparklekit verify <archive>` | Inspect one ZIP or DMG containing one macOS app. | Only temporary extraction or a read-only mount. |
| `sparklekit validate-feed <appcast.xml>` | Validate appcast structure and signed enclosures. | No. |
| `sparklekit verify-update <archive> --appcast PATH --version BUILD` | Cryptographically verify one archive against its appcast EdDSA signature. | No. |
| `sparklekit prepare-release <archive> --version X.Y.Z` | Verify and stage a release through Sparkle's official `generate_appcast`. | Yes, under `.sparklekit/releases/` or `--output`. |
| `sparklekit publish preview [stage]` | Bind and inspect planned assets and permissions without network access. | No. |
| `sparklekit explain <diagnostic-id>` | Explain one stable diagnostic and its remediation. | No. |
| `sparklekit version` | Print toolkit and supported Sparkle versions. | No. |

Run `sparklekit help` for every option. Quickstart and setup can be fully non-interactive by supplying the required metadata and the public `--public-key`.

## Permission boundaries

Passive repository inspection is the default. `--allow-project-execution` permits Xcode-backed inspection or validation that may run target-project build scripts and package plug-ins. `sparklekit test` rejects the command unless this permission is explicit.

Toolkit-initiated package resolution is independent. Pass `--allow-network` only when Xcode must download packages. Once `--allow-project-execution` is granted, the selected project's own build scripts and package plug-ins are trusted executable code and may perform arbitrary I/O; `--allow-network` is not a sandbox for them. `quickstart`, `doctor`, `integrate`, `verify`, and `publish preview` do not initiate network access.

`prepare-release` may execute only the explicitly selected official `generate_appcast` tool. If that executable is inside the target project, `--allow-project-execution` is also required.

## Release policy options

- `--release-mode free`: require Sparkle EdDSA while allowing ad-hoc app signing and treating Apple notarization as optional.
- `--release-mode developer-id`: require Developer ID, Hardened Runtime, Gatekeeper acceptance, and a valid staple in addition to Sparkle EdDSA.
- `--release-mode auto`: inspect capabilities and report an effective mode without obtaining credentials or submitting to Apple.
- `--require-sparkle-signature`: require update-archive authentication.
- `--require-developer-id`: make a missing Developer ID Application signature a failure.
- `--require-notarization`: make missing Gatekeeper acceptance or staple a failure.
- `--allow-ad-hoc-signing`: permit structurally valid ad-hoc signatures in free or auto mode.

`prepare-release` always performs the Ed25519 cryptographic check before staging succeeds. Apple signing and Sparkle signing are reported independently.

## JSON reports

`quickstart`, `setup`, `integrate`, `doctor`, `test`, `verify`, `verify-update`, `validate-feed`, `prepare-release`, `publish preview`, and `explain` support the versioned JSON envelope where applicable. Each diagnostic contains:

- `severity`: `pass`, `warning`, or `failure`
- `id`: stable `SRK` identifier that can be passed to `sparklekit explain`
- `title`: stable check name
- `detail`: observed result
- `remediation`: a concrete repair step when available

Automation must treat any `failure` as incomplete. Warnings remain visible because a free ad-hoc release can be intentional even though Gatekeeper does not give it Developer ID trust.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Command completed successfully. |
| `1` | Unexpected runtime or external-tool failure. |
| `2` | One or more required diagnostics failed. |
| `64` | Invalid command usage or missing input. |
| `65` | Invalid configuration data. |
| `66` | Project could not be found or detected. |
| `78` | Integration state is unsafe or incomplete. |

## Completion boundary

A generated file is not proof of a working updater. Completion requires a Release build, an EdDSA-authenticated archive, a valid appcast, and a real test in which an older installed app discovers and installs a newer build. Record those results with [`AI/VERIFY_RESULT.md`](../AI/VERIFY_RESULT.md), even when a human performs the integration.
