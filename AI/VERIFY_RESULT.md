# Integration verification result

Copy this template into the final integration report.

## Target

- App:
- Bundle identifier:
- Xcode container:
- Scheme:
- Sparkle version:
- Feed URL:

## Commands and results

| Check | Command | Result | Evidence |
| --- | --- | --- | --- |
| Baseline | Project-specific | | |
| SparkleKit doctor | `sparklekit doctor ... --json` | | |
| SparkleKit test | `sparklekit test ... --json` | | |
| Tests | Project-specific | | |
| Release build | `xcodebuild ... -configuration Release` | | |
| Archive | Project-specific | | |
| Archive verification | `sparklekit verify ... --json` | | |
| Appcast validation | `sparklekit validate-feed ... --json` | | |
| Update path | Old build to new build | | |
| Secret scan | Repository-specific | | |

## Manual Xcode changes

- Sparkle package attachment:
- Updater lifetime connection:
- Check for Updates command:

## Remaining risks

- None, or list each unverified requirement explicitly.
