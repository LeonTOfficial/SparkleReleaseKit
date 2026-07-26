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

`prepare-release` never auto-discovers `generate_appcast` from the target repository or the process `PATH`. Pass a reviewed official Sparkle executable with `--generate-appcast`, or deliberately set `SPARKLE_GENERATE_APPCAST`. That process can access the update key in Keychain, so a same-named executable from an untrusted checkout must never be run.

After generation, SparkleReleaseKit independently verifies the Ed25519 signature against the exact archive bytes and checks the enclosure filename, size, and build version. This check is independent from `codesign`, Gatekeeper, and notarization.

## Execution boundaries

Passive project inspection is the default. Xcode-backed inspection and `sparklekit test` may execute target-project build scripts or package plug-ins, so they require separate `--allow-project-execution` consent. SparkleReleaseKit enables automatic Xcode package resolution only when `--allow-network` is also supplied.

Guided quickstart asks before project execution and defaults to No. Configuration writes require a later, separate confirmation that also defaults to No. JSON and non-interactive modes never prompt; automation must provide explicit flags.

Project execution is a broad trust decision. A target repository's own build scripts and package plug-ins may perform arbitrary I/O, including network requests, after execution is allowed. `--allow-network` controls the toolkit's package-resolution action; it does not claim to sandbox malicious project code.

`publish preview` does not access the network or perform remote writes. A future publishing command must retain a distinct remote-write approval and narrowly scoped credentials.

## GitHub Actions

- Give each job only the permissions it needs.
- Pin third-party actions to reviewed commit SHAs for production workflows.
- Use protected environments for release secrets.
- Require review for a production release environment when possible.
- Keep pull-request workflows from untrusted forks away from release secrets.
- Enable dependency review, CodeQL, Dependabot, and secret scanning where available.

## Key loss and rotation

Back up the private Sparkle key securely. Key rotation must follow Sparkle's documented trust-transition rules. Do not replace both the Sparkle key and Developer ID identity in one unplanned update. If the private key is lost, stop publishing and follow the official Sparkle recovery guidance before changing the feed.

## Reporting vulnerabilities

Follow the repository's [security policy](../SECURITY.md). Do not publish private keys, working exploits, or user data in a public issue.
