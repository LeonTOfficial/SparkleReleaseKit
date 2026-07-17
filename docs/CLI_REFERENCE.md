# CLI reference

SparkleReleaseKit commands are intentionally non-destructive unless an explicit apply or release-staging flag is present. Unknown, duplicated, and incomplete options are rejected instead of guessed.

## Common behavior

- Run commands from any directory by passing the target project path explicitly.
- Use `--json` for deterministic automation output where the command supports it.
- Paths printed for reuse in a shell are safely quoted.
- Standard input is disconnected from child tools so automation cannot pause on an unexpected password prompt.
- Private update keys are never valid configuration values or CLI arguments.

## Commands

| Command | Purpose | Writes files? |
| --- | --- | --- |
| `sparklekit setup [project]` | Detect an Xcode app and create `sparklekit.json`. | Configuration only; also integration files with `--apply`. |
| `sparklekit integrate [project]` | Preview generated integration changes. | No. |
| `sparklekit integrate [project] --apply` | Apply the preview with backups and rollback. | Yes. |
| `sparklekit doctor [project]` | Explain configuration and integration problems. | No. |
| `sparklekit test [project]` | Run doctor, package resolution, and a credential-free Release build. | Only temporary derived data outside the project. |
| `sparklekit verify <archive>` | Inspect one ZIP or DMG containing one macOS app. | Only temporary extraction or a read-only mount. |
| `sparklekit validate-feed <appcast.xml>` | Validate appcast structure and signed enclosures. | No. |
| `sparklekit prepare-release <archive> --version X.Y.Z` | Verify and stage a release through Sparkle's official `generate_appcast`. | Yes, under `.sparklekit/releases/` or `--output`. |
| `sparklekit version` | Print toolkit and supported Sparkle versions. | No. |

Run `sparklekit help` for every option. Setup can be fully non-interactive by supplying `--owner`, `--repo`, `--app-name`, `--bundle-id`, `--scheme`, and the public `--public-key`.

## JSON reports

`doctor`, `test`, `verify`, and `validate-feed` return structured diagnostics. Each diagnostic contains:

- `severity`: `pass`, `warning`, or `failure`
- `title`: stable check name
- `detail`: observed result
- `remediation`: a concrete repair step when available

Automation must treat any `failure` as incomplete. Warnings remain visible because an ad-hoc local build can be valid for development while still being unsuitable for public distribution.

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

A generated file is not proof of a working updater. Completion requires a Release build, a signed archive, a valid appcast, and a real test in which an older installed app discovers and installs a newer build. Record those results with [`AI/VERIFY_RESULT.md`](../AI/VERIFY_RESULT.md), even when a human performs the integration.
