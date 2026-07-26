# Quick start

This guide adds Sparkle updates to a regular macOS `.app` built with Xcode.

## Before you begin

You need macOS 13 or later, a current stable Xcode installation, Git, a shared app scheme, and a GitHub repository. A paid Apple Developer membership is optional: use free mode without it, or Developer ID mode for Apple's verified route.

## Install SparkleReleaseKit

The tested release archive is the shortest route:

1. Download [SparkleReleaseKit-macos.zip](https://github.com/LeonTOfficial/SparkleReleaseKit/releases/latest/download/SparkleReleaseKit-macos.zip).
2. Extract it and open Terminal in the extracted `SparkleReleaseKit` folder.
3. Run `./install.sh`, then `sparklekit version`.

The installer writes only to `~/.local/bin` by default and does not request administrator access. A checksum and GitHub artifact attestation accompany every release. If macOS quarantines the currently non-notarized CLI binary, build it locally from source instead:

```bash
git clone https://github.com/LeonTOfficial/SparkleReleaseKit.git
cd SparkleReleaseKit
./scripts/bootstrap.sh
./scripts/install.sh
```

Restart Terminal if `~/.local/bin` was newly added to your `PATH`.

## Run the guided setup

```bash
sparklekit quickstart "/path/to/YourApp"
```

`quickstart` starts the guided experience automatically when standard input is a terminal. It inspects passively first, collects detection results into one review screen, and asks only about missing or ambiguous values. When multiple containers, application targets, or schemes exist, choose one from a numbered list.

Every write confirmation defaults to **No**. Choose **Use**, **Edit**, or **Cancel** at the review screen. Cancelling before apply leaves the managed project files unchanged.

An abbreviated session looks like this:

```text
$ sparklekit quickstart "/Users/me/Projects/MyApp"

SparkleReleaseKit
Guided Sparkle setup

Nothing will be written until you review the plan and approve it.

[1/7] Inspecting Xcode project...
      Passive inspection only; target-project code will not run.
      Allow xcodebuild-backed inspection for more metadata? [y/N]:
      Found MyApp.xcodeproj
      [PASS] Completed in 0.1s

[2/7] Reviewing detected application...
      Container: MyApp.xcodeproj
      Target: MyApp
      Scheme: MyApp
      Style: SwiftUI
      Release mode: Free

      Use this selection?
      [U] Use it
      [E] Edit selection
      [Q] Cancel
      Choice [U]: u
      [PASS] Selection accepted in 0.0s

[3/7] Preparing Sparkle configuration...
[4/7] Reviewing planned changes...
      7 file(s) will be created
      Apply these changes? [y/N]: y
      [PASS] Plan reviewed and approved in 0.0s

[5/7] Applying integration...
      Files written successfully.
      [PASS] Completed in 0.1s

[6/7] Checking integration...
[7/7] Setup ready...
      Files changed: Yes
      Project execution: Not allowed
      Network access: Not used
      [PASS] Guided setup finished in 0.0s
```

The exact files and diagnostics depend on the project. A spinner is used only in a real terminal. Redirected output uses stable heartbeat lines without control characters.

## Generate the update key

Use Sparkle's official `generate_keys` executable once. It stores the private EdDSA key in your login Keychain and prints the public key. Enter or add only the printed public key to `updates.publicEDKey`.

Do not export the private key unless a secured CI workflow requires it. Never commit or paste the private key into an issue, chat, prompt, log, or configuration file.

You may press Return at the public-key prompt during the first pass. SparkleReleaseKit then writes only the configuration when approved and defers updater files until the public key is present.

## Review and apply

The guided flow builds its preview and applies the approved plan in the same session. It creates a backup before transactional writes and rolls managed files back if an apply operation fails.

For a separate manual preview and apply:

```bash
sparklekit integrate "/path/to/YourApp"
sparklekit integrate "/path/to/YourApp" --apply
```

Repeated runs are idempotent. Files that already match are reported as unchanged and are not rewritten.

## Complete the Xcode steps

Open the generated `SparkleReleaseKit/INTEGRATION.md` and complete the project-specific steps that the CLI deliberately does not guess:

1. Add `https://github.com/sparkle-project/Sparkle` with Swift Package Manager and attach the `Sparkle` product to the selected application target.
2. Add or connect `AppUpdater.swift` to the app lifecycle and expose **Check for Updates...**.

SparkleReleaseKit does not silently edit Xcode package dependencies or invent project-specific lifecycle code.

## Execution and network permission

Passive inspection is the `quickstart` default. Approving its xcodebuild question, or passing `--allow-project-execution`, permits target-project build settings, package plug-ins, and build scripts to execute for that command.

`sparklekit test` always requires `--allow-project-execution`. Toolkit-initiated automatic package resolution remains separate and requires `--allow-network`:

```bash
sparklekit test "/path/to/YourApp" --allow-project-execution
sparklekit test "/path/to/YourApp" --allow-project-execution --allow-network
```

`quickstart` performs no network request. `publish preview` is also read-only and network-free.

Treat `--allow-project-execution` as broad trust in the selected project: its own build scripts and package plug-ins are executable code and may perform arbitrary I/O, including their own network requests. `--allow-network` controls SparkleReleaseKit's Xcode package-resolution step; it is not an operating-system sandbox for untrusted project code.

## Automation modes

Use `--non-interactive` in scripts and provide all required values explicitly:

```bash
sparklekit quickstart "/workspace/MyApp" \
  --non-interactive \
  --owner ExampleDeveloper \
  --repo MyApp \
  --public-key "$SPARKLE_PUBLIC_KEY" \
  --with-workflow
```

This previews only. Add `--apply` for an explicit non-interactive write.

Add `--json` for coding agents and CI. JSON mode never prompts or prints progress; standard output contains exactly one versioned JSON document:

```bash
sparklekit quickstart "/workspace/MyApp" \
  --non-interactive \
  --owner ExampleDeveloper \
  --repo MyApp \
  --public-key "$SPARKLE_PUBLIC_KEY" \
  --json
```

Set [`NO_COLOR`](https://no-color.org/) to disable color capability. Plain logs never contain spinner control characters.

## Verify

After the two Xcode steps:

```bash
sparklekit doctor "/path/to/YourApp"
sparklekit test "/path/to/YourApp" --allow-project-execution
```

Then build the app in Release configuration. After packaging a real release:

```bash
sparklekit verify "/path/to/YourApp.zip" --project "/path/to/YourApp"
```

Prepare the signed appcast stage with Sparkle's official tool:

```bash
sparklekit prepare-release "/path/to/YourApp-1.2.0.zip" \
  --project "/path/to/YourApp" \
  --version 1.2.0 \
  --release-mode free \
  --notes "/path/to/release-notes.md" \
  --generate-appcast "/path/to/Sparkle/bin/generate_appcast"
```

Review `.sparklekit/releases/v1.2.0/`. It contains the update archive, appcast, notes, checksum, and release manifest. Then test a real update from an older version using a separate test feed before publishing the production feed.

`quickstart` does not prove that a real update, signature, appcast, or Release build works. Read [Free distribution](FREE_DISTRIBUTION.md) or [Developer ID distribution](DEVELOPER_ID_DISTRIBUTION.md) and complete the end-to-end update test for the selected path.
