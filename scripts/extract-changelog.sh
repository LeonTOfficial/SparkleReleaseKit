#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: extract-changelog.sh VERSION OUTPUT" >&2
  exit 64
fi

version="$1"
output="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
heading="## [$version] - "
matches="$(grep -n -F "$heading" "$root/CHANGELOG.md" || true)"
[[ -n "$matches" && "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" == 1 ]] || {
  echo "CHANGELOG.md must contain exactly one section for $version." >&2
  exit 1
}

start="${matches%%:*}"
temporary="$output.new.$$"
trap 'rm -f "$temporary"' EXIT
tail -n "+$((start + 1))" "$root/CHANGELOG.md" |
  awk '/^## \[/{exit} {print}' > "$temporary"

grep -q '[^[:space:]]' "$temporary" || {
  echo "The CHANGELOG.md section for $version is empty." >&2
  exit 1
}
mv -f "$temporary" "$output"
trap - EXIT
