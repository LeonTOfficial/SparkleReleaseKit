# Contributing

Thank you for helping make secure macOS update delivery easier.

## Before opening a pull request

1. Open an issue for substantial behavior or configuration changes.
2. Keep private keys, certificates, tokens, and proprietary app source out of fixtures and logs.
3. Add focused tests for behavior changes.
4. Run `./scripts/run-tests.sh`.
5. Run the CLI against a disposable fixture or sample project.
6. Update user, AI, schema, and security documentation when a contract changes.

## Design principles

- Preview before mutation.
- Back up before replacing.
- Roll back only files managed by SparkleReleaseKit.
- Prefer structured parsers over text replacement.
- Keep configuration public and secret-free.
- Keep instructions deterministic for humans and coding agents.
- Do not hide unavoidable Xcode or Apple-account steps.

## Commit style

Use a short imperative subject, for example:

```text
Add workspace scheme detection
Harden release archive verification
Clarify EdDSA key setup
```

By contributing, you agree that your contribution is licensed under the MIT License.
