#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_ROOT/.." && pwd)"
CLI="${SPARKLEKIT_CLI:-$KIT_ROOT/.build/release/sparklekit}"

if [[ ! -x "$CLI" ]]; then
  echo "sparklekit is not executable at $CLI" >&2
  exit 1
fi

expect_usage_error() {
  local label="$1"
  shift
  local output
  local status
  set +e
  output="$($CLI "$@" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 64 ]]; then
    printf 'Expected usage exit 64 for %s, got %s\n%s\n' "$label" "$status" "$output" >&2
    exit 1
  fi
}

"$CLI" version | grep -F "SparkleReleaseKit 0.1.0" >/dev/null
"$CLI" help | grep -F "SAFE DEFAULTS" >/dev/null
expect_usage_error "unknown option" doctor --jsno
expect_usage_error "missing option value" setup --owner
expect_usage_error "duplicate option" setup --owner example --owner duplicate
expect_usage_error "extra positional" validate-feed one.xml two.xml

echo "CLI contract checks passed."
