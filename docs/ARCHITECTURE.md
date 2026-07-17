# Architecture

SparkleReleaseKit has three boundaries:

1. `SparkleReleaseKitCore` performs Xcode-backed detection, strict configuration validation, planning, transactional file changes, Release builds, archive inspection, appcast validation, and release staging.
2. `sparklekit` presents deterministic text and JSON commands for people, CI, and coding agents.
3. Generated project files connect the target app to official Sparkle and a reusable release-readiness workflow.

## Safety model

Integration is plan-first. A dry run computes every managed path without writing. Apply mode backs up existing managed files, writes atomically, patches a real Info.plist through `PropertyListSerialization`, and restores its own touched files if an operation fails.

The toolkit deliberately does not rewrite arbitrary `project.pbxproj` files. Xcode has no stable public command-line API for adding a package product to every historical project format, and blind text manipulation is unsafe. The generated integration guide makes this one explicit Xcode action instead.

## Configuration

`sparklekit.json` is the source of truth for public integration metadata. It is described by a JSON Schema and intentionally has no private-key field. The runtime rejects unknown fields rather than letting `Codable` silently ignore them, and a non-empty public key must decode to exactly 32 Ed25519 bytes.

## Release boundary

SparkleReleaseKit does not invent a signing format. `prepare-release` verifies an already packaged app and invokes Sparkle's official `generate_appcast` executable. Its default private-key source is macOS Keychain. Output is prepared in an ignored staging directory and is never published implicitly.

The reusable GitHub workflow builds caller projects without distribution credentials. Production Developer ID signing and notarization remain owned by the application repository and a protected release environment.

Archive inspection performs a ZIP preflight before extraction, caps entry and expansion counts, rejects unsafe member paths, and verifies that extracted symbolic links remain inside the temporary root. Code-sign verification includes nested code; Gatekeeper failure becomes mandatory when `distribution.notarization` is `required` and remains an explicit warning for local or ad-hoc builds.

## Extensibility

Future adapters may support Tuist, XcodeGen, Swift Package Manager executables, multi-target projects, and notarized CI releases. Each adapter must retain preview, rollback, idempotency, strict paths, deterministic JSON, and secret-isolation guarantees.
