# Release process

This is the production sequence for a regular macOS app bundle.

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion`.
2. Finalize localized release notes.
3. Run tests and a clean Release build.
4. Archive with Xcode and export using the Developer ID distribution method.
5. Verify nested code and the outer app signature.
6. Submit the distribution archive with `xcrun notarytool`.
7. Inspect the notary log and staple the accepted ticket.
8. Create the user-facing DMG and the Sparkle update ZIP.
9. Run `sparklekit verify` against both artifacts.
10. Run `sparklekit prepare-release <update.zip> --version X.Y.Z --notes <notes.md> --generate-appcast <path>`.
11. Review the isolated `.sparklekit/releases/vX.Y.Z/` staging directory.
12. Run `sparklekit validate-feed .sparklekit/releases/vX.Y.Z/appcast.xml`.
13. Test an update from a real older build using a separate test feed.
14. Publish the GitHub Release assets.
15. Publish `appcast.xml` and release notes to GitHub Pages.
16. Verify every public URL and perform one final update check from the older build.

## Asset roles

- **DMG:** normal drag-to-Applications installation.
- **ZIP:** clean archive containing only the `.app`, recommended for the Sparkle update asset.
- **appcast.xml:** signed metadata that tells installed apps about updates.
- **Release notes:** human-readable changes shown by Sparkle.

Do not modify a signed appcast or signed release-notes file after generation; regenerate signatures after any content change.

`prepare-release` validates that the app's `CFBundleShortVersionString` matches the requested version, checks archive paths and expansion limits, the bundle identifier, nested code signatures, Gatekeeper status, and the embedded Sparkle framework. It then invokes Sparkle's official generator and leaves publishing as a separate human-approved action.
