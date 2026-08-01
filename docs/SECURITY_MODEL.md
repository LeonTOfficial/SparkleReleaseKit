# Security model

Sparkle updates install executable code. A release pipeline mistake can therefore become a software-supply-chain vulnerability.

## Trust layers

1. **HTTPS** protects the feed and downloads in transit.
2. **Sparkle EdDSA signatures** prove that an update archive was signed by the update key trusted by the installed app.
3. **Apple code signing** binds the app to a Developer ID identity.
4. **Apple notarization** lets Gatekeeper verify that Apple scanned the submitted software and issued a ticket.
5. **GitHub Actions permissions and attestations** record how CI artifacts were produced.

HTTPS and Sparkle EdDSA are mandatory for the update channel. Apple Developer ID and notarization add a separate Apple-verified trust path, but they are optional in the supported free-distribution mode.

## Secret handling

Public and private keys are different:

- `SUPublicEDKey` belongs in the app and may be committed.
- The private EdDSA key signs releases and must remain private.
- Developer ID `.p12` files, App Store Connect `.p8` files, passwords, and tokens are private.

SparkleReleaseKit ignores common private-key formats and `.sparklekit/private/`, but `.gitignore` is only a final guard. Keep private material in macOS Keychain or encrypted CI secrets and avoid printing it.

## Release signing

- Use Sparkle's official `generate_appcast` to create EdDSA signatures.
- For free distribution, prefer consistent ad-hoc signing and document Gatekeeper's one-time approval.
- For optional Apple-verified distribution, use Developer ID with Hardened Runtime.
- In Developer ID mode, use `xcrun notarytool`, inspect the returned log, and staple the ticket.
- Sign nested code according to Apple's bundle rules before signing the outer app.
- Do not use `codesign --deep` as a shortcut for release signing.

`prepare-release` never auto-discovers `generate_appcast` from the target
repository or the process `PATH`. Pass a reviewed official Sparkle executable
with `--generate-appcast`, or deliberately set
`SPARKLE_GENERATE_APPCAST`. An explicit CLI path always wins. In CI the
environment override is rejected unless it is explicitly enabled.

`GenerateAppcastTrustPolicy` resolves every symlink to a canonical absolute
path and then requires:

- the exact `generate_appcast` filename;
- a regular executable owned by root or the current user;
- no group- or world-writable helper or unsafe parent directory;
- explicit permission before executing a helper inside the target project;
- a valid strict code signature when configured;
- the configured signing identifier, Team ID, and designated requirement; and
- an exact match when a SHA-256 allowlist is configured.

The selected path source, canonical path, SHA-256, and inspected signing
identity are recorded in diagnostics and the release manifest. Trust failures
do not echo environment values. The helper receives only a minimal environment
needed for Keychain operation; GitHub tokens, cloud credentials, SSH agent
variables, and unrelated CI secrets are not inherited.

After generation, SparkleReleaseKit independently verifies the Ed25519 signature against the exact archive bytes and checks the enclosure filename, size, and build version. This check is independent from `codesign`, Gatekeeper, and notarization.

## Execution boundaries

Passive project inspection is the default. Xcode-backed inspection and `sparklekit test` may execute target-project build scripts or package plug-ins, so they require separate `--allow-project-execution` consent. SparkleReleaseKit enables automatic Xcode package resolution only when `--allow-network` is also supplied.

Guided quickstart asks before project execution and defaults to No. Configuration writes require a later, separate confirmation that also defaults to No. JSON and non-interactive modes never prompt; automation must provide explicit flags.

Project execution is a broad trust decision. A target repository's own build scripts and package plug-ins may perform arbitrary I/O, including network requests, after execution is allowed. `--allow-network` controls the toolkit's package-resolution action; it does not claim to sandbox malicious project code.

`publish preview` does not access the network or perform remote writes. A future publishing command must retain a distinct remote-write approval and narrowly scoped credentials.

## SparkleReleaseKit self-update

The CLI update channel has a separate Ed25519 trust root from app update keys.
Its private key exists only in the protected GitHub `release` environment; the
public key is embedded in the CLI.

`update check` verifies bounded manifest and detached-signature responses over
credential-free HTTPS and does not write. `update install` verifies the signed
manifest, exact asset size, SHA-256, safe ZIP layout, extracted tree, and strict
code signature before activation. It rejects downgrades by default, never
executes the downloaded binary during verification, and uses a private
directory, process lock, atomic activation, hashed rollback reference, and
automatic transaction rollback. Manual rollback re-verifies the saved binary.

Optional update hints run only for installed interactive builds, at most once
in 24 hours, with a two-second background timeout. They never install, never
block a normal command, and are disabled in JSON and CI. The preference file
stores only the Boolean setting and last-check time. No telemetry, project
metadata, personal data, or device identifier is sent.

## Managed project migration

Schema v4 records generated tool version, migration ID, managed paths, template
versions, and original template SHA-256 values. `project upgrade` uses those
hashes only to prove that a generated file remains unchanged. Missing proof or
a mismatched hash becomes a conflict; manual content is preserved.

Apply requires an explicit flag, reuses project containment and symlink
protections, snapshots every path, creates a backup, locks the project, writes
atomically, and restores all touched paths after failure. Unknown project files
are never deleted.

## GitHub Actions

- Give each job only the permissions it needs.
- Pin third-party actions to reviewed commit SHAs for production workflows.
- Use protected environments for release secrets.
- Require review for a production release environment when possible.
- Keep pull-request workflows from untrusted forks away from release secrets.
- Enable dependency review, CodeQL, Dependabot, and secret scanning where available.

The SparkleReleaseKit tag workflow uses minimal `contents`, `id-token`, and
`attestations` permissions. It requires the protected self-update signing key,
emits signed update and build metadata, and creates provenance attestations.
Apple credentials are optional and are used only in that release environment:
when complete, the workflow applies Developer ID with Hardened Runtime, submits
a DMG to `notarytool`, staples and validates the ticket, and runs Gatekeeper
assessment. Their absence never blocks pull-request CI.

## Key loss and rotation

Back up the private Sparkle key securely. Key rotation must follow Sparkle's documented trust-transition rules. Do not replace both the Sparkle key and Developer ID identity in one unplanned update. If the private key is lost, stop publishing and follow the official Sparkle recovery guidance before changing the feed.

## Reporting vulnerabilities

Follow the repository's [security policy](../SECURITY.md). Do not publish private keys, working exploits, or user data in a public issue.
