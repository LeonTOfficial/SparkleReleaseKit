# Sparkle update signing

Sparkle update signing and Apple code signing are different trust layers.

## Sparkle EdDSA

- Sparkle's private Ed25519 key signs the update archive.
- The installed app contains only `SUPublicEDKey`.
- Sparkle rejects an archive whose bytes do not match its signature.
- This works in both free and Developer ID distribution modes.

Generate the key once with Sparkle's official `generate_keys` tool. Keep the private key in macOS Keychain and back it up securely. Commit only the public key.

`prepare-release` invokes the explicitly selected official `generate_appcast` executable, then independently checks:

- appcast XML structure;
- credential-free HTTPS enclosure URL;
- archive filename;
- declared byte length;
- `sparkle:version` against the app build number;
- 64-byte signature encoding;
- the real Ed25519 signature against the exact archive bytes.

Before execution, `GenerateAppcastTrustPolicy` canonicalizes the helper path,
checks ownership and write permissions for the file and its parents, requires a
regular executable, verifies its strict code signature when configured, and
enforces optional signing-identifier, Team-ID, designated-requirement, and
SHA-256 allowlist constraints. The helper receives a minimal environment so
unrelated CI and cloud credentials are not inherited.

This app-update key is unrelated to the dedicated manifest key used by
`sparklekit update`. Compromise or rotation of one trust root must not silently
replace the other.

You can repeat the cryptographic check independently:

```bash
sparklekit verify-update MyApp-1.2.0.zip \
  --appcast appcast.xml \
  --version 120 \
  --project /path/to/MyApp
```

## Apple signing

- Ad-hoc signing is a local structural signature without an Apple identity.
- Apple Development signing is for development and testing.
- Developer ID signing identifies a direct-distribution developer.
- Notarization is Apple's separate scan and ticket service.

None of those replaces Sparkle EdDSA. A Developer ID app still needs a signed Sparkle archive, and a free ad-hoc app can still use strong Sparkle update authentication.

## Key rotation

Do not casually replace `SUPublicEDKey`. Key rotation is a trust migration that must follow Sparkle's official guidance while an older trusted build can still authorize the transition. If the private key is lost, stop publishing updates and follow a reviewed recovery plan.
