# Install SparkleReleaseKit

SparkleReleaseKit supports macOS 13 or later. The release CLI is universal
`arm64` and `x86_64`; building from source requires the current stable Xcode and
Swift toolchain documented in the release metadata.

## Install a tested release

1. Download `SparkleReleaseKit-macos.zip` and
   `SparkleReleaseKit-macos.zip.sha256` from the same GitHub release.
2. Verify the checksum:

   ```bash
   shasum -a 256 -c SparkleReleaseKit-macos.zip.sha256
   ```

3. Optionally verify GitHub provenance:

   ```bash
   gh attestation verify SparkleReleaseKit-macos.zip \
     --repo LeonTOfficial/SparkleReleaseKit
   ```

4. Extract the ZIP and run its installer:

   ```bash
   ditto -x -k SparkleReleaseKit-macos.zip extracted
   extracted/SparkleReleaseKit/install.sh
   sparklekit version
   ```

The default destination is `~/.local/bin`. Set
`SPARKLEKIT_INSTALL_DIR` to use another writable directory. Paths containing
spaces are supported. The installer does not require `sudo`.

When a release includes `SparkleReleaseKit-macos.dmg`, that image contains the
same CLI signed with Developer ID, notarized by Apple, and stapled. Validate it
with:

```bash
xcrun stapler validate SparkleReleaseKit-macos.dmg
spctl --assess --type open \
  --context context:primary-signature \
  --verbose=4 SparkleReleaseKit-macos.dmg
```

## Build from source

```bash
git clone https://github.com/LeonTOfficial/SparkleReleaseKit.git
cd SparkleReleaseKit
./scripts/run-tests.sh
./scripts/install.sh
sparklekit version
```

This path builds locally and does not use the CLI self-update manifest.

## Verify the installed files

```bash
command -v sparklekit
codesign --verify --strict --verbose=2 "$(command -v sparklekit)"
sparklekit version
```

The executable requires its adjacent
`SparkleReleaseKit_SparkleReleaseKitCore.bundle`. Do not move only the binary.

## Uninstall

Remove the executable, its resource bundle, and the installation directory's
`.sparklekit` update state only after confirming the directory is dedicated to
SparkleReleaseKit. User update preferences are stored separately at:

```text
~/Library/Application Support/SparkleReleaseKit/preferences.json
```

No telemetry identifier or personal information is stored.
