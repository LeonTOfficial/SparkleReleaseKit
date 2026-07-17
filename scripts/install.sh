#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
KIT_ROOT="${SCRIPT_ROOT:h}"
INSTALL_DIR="${SPARKLEKIT_INSTALL_DIR:-$HOME/.local/bin}"
BUNDLE_NAME="SparkleReleaseKit_SparkleReleaseKitCore.bundle"

if [[ -x "$SCRIPT_ROOT/sparklekit" && -d "$SCRIPT_ROOT/$BUNDLE_NAME" ]]; then
  SOURCE_BINARY="$SCRIPT_ROOT/sparklekit"
  SOURCE_BUNDLE="$SCRIPT_ROOT/$BUNDLE_NAME"
else
  for tool in swift xcodebuild; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      print -u2 "Missing required tool: $tool"
      exit 1
    fi
  done
  swift build --package-path "$KIT_ROOT" -c release
  SOURCE_BINARY="$KIT_ROOT/.build/release/sparklekit"
  SOURCE_BUNDLE="$KIT_ROOT/.build/release/$BUNDLE_NAME"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/SparkleReleaseKit-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$SOURCE_BINARY" "$STAGE/sparklekit"
cp -R "$SOURCE_BUNDLE" "$STAGE/$BUNDLE_NAME"
chmod 755 "$STAGE/sparklekit"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$BUNDLE_NAME"
mv "$STAGE/$BUNDLE_NAME" "$INSTALL_DIR/$BUNDLE_NAME"
mv "$STAGE/sparklekit" "$INSTALL_DIR/sparklekit"
chmod 755 "$INSTALL_DIR/sparklekit"

print "Installed sparklekit to $INSTALL_DIR/sparklekit"
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  print "Add this directory to PATH: export PATH=\"$INSTALL_DIR:\$PATH\""
fi
