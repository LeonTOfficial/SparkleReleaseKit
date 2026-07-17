# Update key management

The Sparkle Ed25519 private key is the authority to publish executable updates. Treat it like a production signing credential.

## Local development

Run Sparkle's official `generate_keys` tool once. By default it stores the private key in your macOS login Keychain under the `ed25519` account and prints the public key.

- Commit the public key through `SUPublicEDKey` and `sparklekit.json`.
- Keep the private key in Keychain.
- Use a separate test key and test feed before the first production release.
- Keep an encrypted offline backup whose restore procedure has actually been tested.

`sparklekit prepare-release` asks `generate_appcast` to read the private key from Keychain. It does not accept raw private key text in the configuration.

Use only the official `generate_appcast` executable from a Sparkle release you have reviewed. SparkleReleaseKit deliberately does not execute a copy discovered inside the target project because that process receives Keychain access to the update-signing key.

## CI

If release signing must run in GitHub Actions, export the private key only into an encrypted secret in a protected release environment. Pass it to Sparkle's tool through standard input with `--ed-key-file -`, exactly as documented by Sparkle. Never place it in a command argument, workflow file, artifact, cache, pull-request job, or log.

Use environment approval, minimal token permissions, immutable action SHAs, and no release secrets on workflows triggered by untrusted forks.

## Loss or exposure

If the private key is lost, stop publishing. Do not silently replace `SUPublicEDKey`; installed apps trust the old key. Follow Sparkle's official key migration or recovery guidance and test the transition from a real installed version.

If the private key is exposed:

1. Remove public access to the leaked material without assuming deletion erases history.
2. Treat the key as compromised.
3. Preserve evidence and identify affected releases.
4. Follow Sparkle's trust-transition guidance before rotating.
5. Notify users clearly if update trust may have been affected.

Avoid rotating the Sparkle key and Developer ID identity in the same unplanned release; that makes diagnosis and recovery harder.
