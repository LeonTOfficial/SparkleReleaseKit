# Proposed GitHub release governance

These settings are a reproducible proposal. They are not applied by repository
files and must not be enabled until Leon approves the exact names and bypass
owners in GitHub.

## Main ruleset: `main-reviewed`

- Target: branch `main`; enforcement: active.
- Require a pull request with one approving review and dismissal of stale
  approvals after new commits.
- Require conversation resolution and the latest reviewed push.
- Require status checks `Swift 6 build and tests`, `Package manifest
  portability`, `Dependency review` for pull requests, and `Analyze Swift`.
- Require CodeQL results, block force pushes and deletion, and require linear
  history.
- Bypass: repository owner only, `pull_requests` mode, with a required written
  reason. Do not grant GitHub Actions a general bypass.

## Tag ruleset: `stable-release-tags`

- Target: tags matching `v*`; enforcement: active.
- Restrict creation, updates, deletion, and force updates.
- Permit creation only to the repository owner after the release commit is the
  current reviewed `main` head.
- Create future releases as signed annotated tags. Keep the existing `v0.4.0`
  tag unchanged. Pin the accepted signing identity before adding automated
  `git verify-tag` enforcement.
- Historical releases use only the workflow's visible manual
  `historical_exception` input and must name an already existing annotated tag.

## Release environment: `release`

- Required reviewer: Leon; prevent self-review only if a second trusted
  reviewer is available.
- Wait timer: 10 minutes.
- Deployment branches and tags: selected tags matching `v*` only.
- Store only the CLI manifest key and optional Developer ID/notary credentials
  here. Build and test remain in the unprivileged `validate-build` job.

## Repository settings

- Enable immutable releases after confirming the current GitHub plan supports
  them and the release workflow remains compatible.
- Keep Actions restricted to explicitly allowed actions and reusable workflows;
  every `uses:` reference in this repository remains pinned to a full commit
  SHA.
- Disable force pushes and branch/tag deletion through the rulesets above.
- Review admin bypass use in the audit log after every release.

Applying this proposal is a separate administrative change. It is not part of
the code patch and requires Leon's explicit approval.
