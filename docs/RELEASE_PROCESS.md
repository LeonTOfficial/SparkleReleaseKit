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
