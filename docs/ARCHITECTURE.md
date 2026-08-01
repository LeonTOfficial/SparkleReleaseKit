# Architecture

SparkleReleaseKit has six boundaries:

1. `SparkleReleaseKitCore` performs Xcode-backed detection, strict configuration validation, planning, transactional file changes, Release builds, archive inspection, appcast validation, and release staging.
2. `SparkleReleaseKitCLISupport` owns injectable terminal input, guided decisions, sanitization, and TTY/plain progress reporting without depending on the executable entry point.
3. `sparklekit` presents guided human commands and deterministic JSON commands for CI and coding agents.
4. Generated project files connect the target app to official Sparkle and a reusable release-readiness workflow.
5. `ProjectUpgrader` compares generated files with recorded template hashes and delegates conflict-free writes to the same integration transaction.
6. `SelfUpdater` verifies the toolkit's independent signed release metadata, bounded package, SHA-256, archive tree, and code signature before `SelfUpdateInstaller` atomically activates it.

## Safety model

Integration is plan-first. A dry run computes every managed path without writing. Apply mode takes stable snapshots, acquires a project lock, revalidates concurrent state, backs up existing managed files, writes atomically, patches a real Info.plist through `PropertyListSerialization`, and restores its own touched files if an operation fails.

Interactive quickstart and machine automation share the same detector, configuration, plan, and integrator. The terminal layer changes presentation only. JSON mode bypasses prompts and progress so standard output remains one versioned document.

The toolkit deliberately does not rewrite arbitrary `project.pbxproj` files. Xcode has no stable public command-line API for adding a package product to every historical project format, and blind text manipulation is unsafe. The generated integration guide makes this one explicit Xcode action instead.

## Configuration

`sparklekit.json` is the source of truth for public integration metadata.
Schema v4 models free, Developer ID, and auto release policies, explicit app
update channels, `generate_appcast` trust requirements, and managed-file
migration metadata. Schemas v1 through v3 receive controlled in-memory defaults
and are rewritten only by an explicit apply. It intentionally has no
private-key field. The runtime rejects unknown fields rather than letting
`Codable` silently ignore them, and a non-empty public key must decode to
exactly 32 Ed25519 bytes.

Generated files have two ownership records: `sparklekit.json` stores original
template hashes and versions, while `.sparklekit/manifest.json` stores the
exact last-applied hashes. A migration may update only a file whose current
hash proves that the developer has not changed it. Diffs are bounded and
potentially sensitive lines are redacted.

## Release boundary

SparkleReleaseKit does not invent an app-signing format. `prepare-release`
verifies an already packaged app and invokes Sparkle's official
`generate_appcast` executable after a centralized path, permission,
ownership, code-signature, identity, and optional SHA-256 trust decision. Its
default private-key source is macOS Keychain. The toolkit then verifies the
resulting Ed25519 signature with CryptoKit, emits SHA-256 and a deterministic
manifest, and never publishes implicitly.

The reusable GitHub workflow builds caller projects without distribution credentials. Optional Developer ID signing and notarization remain owned by the application repository and a protected release environment.

Archive inspection performs a ZIP preflight before extraction, caps entry and expansion counts, rejects unsafe member paths, and verifies that extracted symbolic links remain inside the temporary root. Verification classifies signatures and architectures explicitly. Gatekeeper and staple failures block Developer ID mode and remain visible warnings in free mode.

## CLI update boundary

The SparkleReleaseKit CLI uses a dedicated update trust root unrelated to an
app's Sparkle key. Release metadata signs the version, channel, source commit,
minimum macOS version, release notes, asset URL, byte count, SHA-256, and exact
package layout. Network transports require HTTPS, reject credentials and unsafe
redirects, enforce timeouts, and stop oversized responses.

Installation uses a lock and versioned private directories. The active
executable is an atomic symlink reference; rollback state includes paths,
versions, permissions, signature requirement, and SHA-256. The executable is
never launched as part of verification. User update-hint preferences are
separate from project configuration and contain no telemetry identity.

## Extensibility

Future adapters may support Tuist, XcodeGen, Swift Package Manager executables, multi-target projects, and notarized CI releases. Each adapter must retain preview, rollback, idempotency, strict paths, deterministic JSON, and secret-isolation guarantees.
