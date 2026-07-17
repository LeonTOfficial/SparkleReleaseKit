#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
KIT_ROOT="${SCRIPT_ROOT:h}"

for tool in swift xcodebuild git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -u2 "Missing required tool: $tool"
    exit 1
  fi
done

swift build --package-path "$KIT_ROOT" -c release
print ""
print "SparkleReleaseKit is ready."
print "Run: $KIT_ROOT/sparklekit help"
