# Update the SparkleReleaseKit CLI

CLI self-update is separate from updating an app, migrating generated project
files, or changing the Sparkle package dependency.

## Check without changing files

```bash
sparklekit update check
sparklekit update check --json
```

The command downloads only bounded manifest and signature files over HTTPS. It
verifies the detached Ed25519 signature with the public trust root embedded in
the installed CLI, then reports the installed and available versions and
release-note summary.

Only the separately published `stable` source is enabled in v0.4. Beta is
reserved for a future channel with its own explicit source metadata.

## Install explicitly

```bash
sparklekit update install
```

Installation never starts from an update hint and never runs automatically. The
installer:

1. verifies the signed release manifest;
2. rejects unsafe URLs, oversized responses, and downgrades by default;
3. downloads the bounded ZIP to a private temporary directory;
4. verifies exact byte length and SHA-256;
5. rejects traversal, symbolic links, special files, excessive entries, and
   excessive expansion;
6. verifies the extracted executable with `codesign --verify --strict`;
7. copies the executable and resource bundle into a private version directory;
8. atomically activates the new executable;
9. records a hashed rollback reference; and
10. restores the previous installation after any transaction failure.

The downloaded executable is never run during verification. App projects are
not read or changed.

Use `--install-path "/path with spaces/sparklekit"` only when the running
executable cannot be resolved from `PATH`. Use `--allow-downgrade` only for an
explicitly reviewed recovery; the older release must still have valid signed
metadata.

## Roll back

```bash
sparklekit update rollback
```

Rollback verifies the saved executable's regular-file status, SHA-256,
permissions, required code signature, adjacent resource-bundle tree, and
containment inside the private managed installation directory before atomically
restoring it. Only the most recent verified installation is selected. Rollback
never changes app projects.

## Optional update hints

Installed interactive builds may perform a best-effort two-second background
check at most once in 24 hours. The normal command never waits for it, failures
are silent, and it never installs. Checks are disabled in JSON, CI,
non-interactive, help, version, update, and config commands.

Disable or inspect the preference:

```bash
sparklekit config set update-check false
sparklekit config get update-check
```

The local preference contains only its schema version, the Boolean setting, and
the last check time. SparkleReleaseKit sends no telemetry, device identifier,
project metadata, personal data, or credentials.

## Release trust root

The matching private manifest-signing key exists only as
`SPARKLEKIT_UPDATE_SIGNING_PRIVATE_KEY` in the protected GitHub `release`
environment. The tagged release workflow creates and immediately verifies:

- `sparklekit-update-manifest.json`;
- `sparklekit-update-manifest.json.sig`;
- the ZIP and its SHA-256 checksum;
- `sparklekit-build-metadata.json`; and
- GitHub build-provenance attestations.

Key rotation requires a planned transition release. Replacing the embedded
public key without first shipping it through the currently trusted channel
would strand older installations.
