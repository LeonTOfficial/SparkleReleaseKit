# Release process

This is the production sequence for a regular macOS app bundle. Choose either [free distribution](FREE_DISTRIBUTION.md) or [Developer ID distribution](DEVELOPER_ID_DISTRIBUTION.md) before step 4.

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion`.
2. Finalize localized release notes.
3. Run tests and a clean Release build.
4. Archive with Xcode and export the app.
5. Verify nested code and the outer app signature. Free mode accepts ad-hoc signing; Developer ID mode requires its Apple identity.
6. In Developer ID mode only, submit with `xcrun notarytool`.
7. In Developer ID mode only, inspect the notary log and staple the accepted ticket.
8. Create the user-facing DMG and the Sparkle update ZIP.
9. Run `sparklekit verify` against both artifacts.
10. Run `sparklekit prepare-release <update.zip> --version X.Y.Z --notes <notes.md> --generate-appcast <path>`.
11. Review the isolated `.sparklekit/releases/vX.Y.Z/` staging directory.
12. Run `sparklekit validate-feed .sparklekit/releases/vX.Y.Z/appcast.xml` and `sparklekit verify-update`.
13. Test an update from a real older build using a separate test feed.
14. Publish the GitHub Release assets.
15. Publish `appcast.xml` and release notes to GitHub Pages.
16. Verify every public URL and perform one final update check from the older build.

## Asset roles

- **DMG:** normal drag-to-Applications installation.
- **ZIP:** clean archive containing only the `.app`, recommended for the Sparkle update asset.
- **appcast.xml:** signed metadata that tells installed apps about updates.
- **Release notes:** human-readable changes shown by Sparkle.
- **SHA-256:** independent archive checksum for release review.
- **release-manifest.json:** deterministic metadata recording mode, versions, architecture, signature class, and verification state.

Do not modify a signed appcast or signed release-notes file after generation; regenerate signatures after any content change.

`prepare-release` validates that the app's `CFBundleShortVersionString` matches the requested version, checks archive paths and expansion limits, bundle identifier, architecture, app-signing policy, Gatekeeper status, and embedded Sparkle. It invokes Sparkle's official generator, independently verifies its Ed25519 signature against the exact archive, writes the checksum and manifest, and leaves publishing as a separate human-approved action.

## Trust the selected generate_appcast

Prefer an explicit path and pin the reviewed helper in `sparklekit.json`:

```json
{
  "tools": {
    "generateAppcast": {
      "requireValidSignature": true,
      "expectedSigningIdentifier": "generate_appcast-EXPECTED_IDENTIFIER",
      "expectedTeamIdentifier": null,
      "designatedRequirement": null,
      "allowedSHA256": ["REVIEWED_64_CHARACTER_SHA256"],
      "allowEnvironmentOverrideInCI": false
    }
  }
}
```

The official Sparkle 2.9.4 binary is ad-hoc signed and may have no Team ID, so
an exact SHA-256 allowlist is the strongest practical pin when that distributed
binary is used. Recalculate and review the hash whenever Sparkle is upgraded.
Do not weaken the policy merely to make an unfamiliar helper run.

## Release SparkleReleaseKit itself

SparkleReleaseKit's own tag workflow is separate from an app release:

1. Update `SparkleReleaseKitVersion.current`, `CHANGELOG.md`, schemas, and docs.
2. Run `scripts/run-tests.sh` and the universal release build locally.
3. Merge the exact release commit to `main`.
4. Create an annotated `vX.Y.Z` tag on that commit.
5. The protected `release` environment supplies only the dedicated CLI update
   manifest key and optional Apple release credentials.
6. The workflow rebuilds and tests the tag, verifies tag ancestry and version,
   signs the binary, and emits `sparklekit-build-metadata.json`.
7. It packages and verifies the ZIP, checksum, universal architectures,
   strict code signature, installer, and CLI version.
8. It creates `sparklekit-update-manifest.json` and its detached Ed25519
   signature, then verifies them with the same embedded trust root used by
   `sparklekit update`.
9. With complete Apple credentials it also creates a Developer-ID signed,
   notarized, stapled, and Gatekeeper-assessed DMG. Missing Apple credentials
   never affect pull-request CI.
10. It creates GitHub provenance attestations before publishing every asset.

The release must include:

- `SparkleReleaseKit-macos.zip`;
- `SparkleReleaseKit-macos.zip.sha256`;
- `sparklekit-update-manifest.json`;
- `sparklekit-update-manifest.json.sig`;
- `sparklekit-build-metadata.json`; and
- the optional DMG and checksum when Apple verification was completed.

After publication, download the public assets into a fresh temporary directory,
verify checksum and attestation, inspect the universal binary and code
signature, run the packaged installer, verify `sparklekit version`, and run
`sparklekit update check`.
