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
