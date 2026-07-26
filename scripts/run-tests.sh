#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
KIT_ROOT="${SCRIPT_ROOT:h}"

/usr/bin/swift package --package-path "$KIT_ROOT" resolve
/usr/bin/swift build --package-path "$KIT_ROOT" --configuration release
/usr/bin/swift test --package-path "$KIT_ROOT" --parallel
"$KIT_ROOT/.build/release/sparklekit" version
SPARKLEKIT_CLI="$KIT_ROOT/.build/release/sparklekit" "$KIT_ROOT/scripts/test-cli.sh"
/usr/bin/python3 "$KIT_ROOT/scripts/test_check_site.py"
"$KIT_ROOT/scripts/check-site.sh"
