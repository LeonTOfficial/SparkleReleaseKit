# Security policy

## Supported versions

Security fixes are provided for the latest released minor version of SparkleReleaseKit.

## Report a vulnerability

Do not open a public issue for vulnerabilities, exposed credentials, signing-key concerns, or a working exploit.

Use GitHub's private vulnerability reporting for this repository. Include:

- affected version or commit;
- affected command and target-project type;
- impact and realistic attack scenario;
- minimal reproduction steps;
- suggested remediation, if known.

Please remove private keys, tokens, certificates, personal data, and unrelated project source from all reports. You should receive an acknowledgement within seven days.

## Scope

High-priority reports include private-key disclosure, command injection, path traversal outside the target repository, unsafe rollback, untrusted workflow execution with release secrets, signature-verification bypasses, and generated configurations that weaken macOS security controls.

Sparkle itself is maintained separately. Vulnerabilities in Sparkle should follow the Sparkle project's security process.
