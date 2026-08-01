# Troubleshooting

## `No .xcodeproj or .xcworkspace was found`

Pass the repository directory that directly contains the Xcode project or workspace.

## The wrong scheme was detected

Share the intended app scheme in Xcode, then rerun setup with `--scheme "Your Scheme"`.

## The public key is missing

Run Sparkle's official `generate_keys` tool. Copy only its printed public key into `updates.publicEDKey`.

## Sparkle does not appear in the app bundle

In the app target's **General** settings, ensure the Sparkle product is linked and embedded. Then create a fresh Release build and run `sparklekit verify`.

## Update checks find nothing

Confirm all of the following:

- `SUFeedURL` is the exact public HTTPS appcast URL.
- The URL returns XML and not a 404 page.
- `CFBundleVersion` increases for every release.
- The appcast enclosure points to an existing archive.
- The enclosure has a valid EdDSA signature and byte length.
- The installed app is older than the published update.

Sparkle logs detailed reasons in Console.app under the host application's process.

## The update downloads but fails to install

Run `sparklekit verify` on the exact uploaded asset. Check code signing, bundle identifier, nested frameworks, notarization, and whether the app is running from a writable Applications directory rather than a read-only DMG.

## CI cannot access the private key

Do not put the key in the repository. Configure it as an encrypted repository or environment secret and make it available only to the release job. Pull-request jobs must not receive release secrets.

## `generate_appcast` is rejected

Use the exact official helper from the reviewed Sparkle release. Confirm its
canonical path, owner, file and parent permissions, strict code signature,
signing identifier, Team ID, designated requirement, and SHA-256 against
`tools.generateAppcast`. An environment path is rejected in CI unless the
override is explicitly allowed. Do not weaken the rule before identifying why
the helper changed.

## CLI update check cannot reach GitHub

Normal commands continue even when an optional background hint fails. For an
explicit diagnosis, run:

```bash
sparklekit update check --timeout 30
```

Confirm HTTPS access to the latest GitHub release assets. A signature error is
not a network error; stop and inspect the release rather than bypassing it.

## CLI update install fails

Check that the installation directory is writable and that the executable and
resource bundle are still present. Do not run the downloaded binary manually.
The transaction leaves the current version active or restores it on failure.
Use `sparklekit update rollback` only when a verified previous installation
exists.

## Project upgrade reports a conflict

The managed file differs from its recorded original SHA-256 or lacks ownership
evidence. Review the bounded diff, merge the new behavior manually or restore a
trusted generated version, then preview again. Do not edit the manifest hash to
silence the conflict.
