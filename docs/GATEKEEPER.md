# Gatekeeper and first launch

Gatekeeper is Apple's policy for opening downloaded software. It is separate from Sparkle's EdDSA update signature.

| Distribution | Sparkle archive authenticated | Apple identity verified | Typical first launch |
| --- | --- | --- | --- |
| Free + ad-hoc | Yes | No | macOS may require one manual approval |
| Developer ID + notarized | Yes | Yes | Normally opens without the independent-developer block |

## Safe first-launch guidance for free builds

If macOS blocks the app:

1. Open **System Settings**.
2. Select **Privacy & Security**.
3. Scroll to the Security section.
4. Find the message that the app was blocked.
5. Click **Open Anyway** and confirm.

Do not advise users to disable Gatekeeper globally, change system-wide security policy, or run unexplained quarantine-removal commands.

## What SparkleReleaseKit checks

- `codesign --verify --deep --strict` for structural integrity.
- The actual signing class: unsigned, ad-hoc, Apple Development, Developer ID, or other.
- Hardened Runtime when Developer ID is required.
- Optional expected Apple Team ID.
- `spctl` Gatekeeper assessment.
- `stapler validate` for the notarization ticket.

In free mode, missing Developer ID, Gatekeeper acceptance, or a staple is a visible warning. In `developer-id` mode, the same condition is a release-blocking failure.
