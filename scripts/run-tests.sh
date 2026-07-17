#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
KIT_ROOT="${SCRIPT_ROOT:h}"

swift package --package-path "$KIT_ROOT" resolve
swift build --package-path "$KIT_ROOT" --configuration release
swift test --package-path "$KIT_ROOT" --parallel
"$KIT_ROOT/.build/release/sparklekit" version
SPARKLEKIT_CLI="$KIT_ROOT/.build/release/sparklekit" "$KIT_ROOT/scripts/test-cli.sh"
"$KIT_ROOT/scripts/check-site.sh"
