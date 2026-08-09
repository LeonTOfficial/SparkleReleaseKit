#!/bin/zsh
set -euo pipefail

SCRIPT_ROOT="${0:A:h}"
KIT_ROOT="${SCRIPT_ROOT:h}"
INSTALL_DIR="${SPARKLEKIT_INSTALL_DIR:-$HOME/.local/bin}"
BUNDLE_NAME="SparkleReleaseKit_SparkleReleaseKitCore.bundle"
MANAGED_ROOT="$INSTALL_DIR/.sparklekit"
VERSIONS_DIR="$MANAGED_ROOT/versions"
ACTIVE_LINK="$MANAGED_ROOT/current"
LOCK_DIR="$MANAGED_ROOT/install.lock"
PUBLIC_BINARY="$INSTALL_DIR/sparklekit"
PUBLIC_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME"
STAGE=""
OLD_TARGET=""
ACTIVATED=0
CREATED_PUBLIC_LINKS=0
LOCK_HELD=0

fail_at() {
  local point="$1"
  if [[ "${SPARKLEKIT_INSTALL_FAIL_AT:-}" == "$point" ]]; then
    print -u2 "Injected installer failure at $point."
    return 97
  fi
  return 0
}

replace_link() {
  local target="$1"
  local destination="$2"
  local temporary="$destination.new.$$"
  /bin/rm -f "$temporary"
  /bin/ln -s "$target" "$temporary"
  /bin/mv -fh "$temporary" "$destination"
}

restore_previous() {
  if (( ACTIVATED != 1 )); then
    if [[ -n "$OLD_TARGET" ]]; then
      replace_link ".sparklekit/current/sparklekit" "$PUBLIC_BINARY"
      /bin/rm -rf "$PUBLIC_BUNDLE"
      replace_link ".sparklekit/current/$BUNDLE_NAME" "$PUBLIC_BUNDLE"
    elif (( CREATED_PUBLIC_LINKS == 1 )); then
      /bin/rm -f "$PUBLIC_BINARY" "$PUBLIC_BUNDLE"
      CREATED_PUBLIC_LINKS=0
    fi
    return 0
  fi
  ACTIVATED=0
  if [[ -n "$OLD_TARGET" ]]; then
    replace_link "$OLD_TARGET" "$ACTIVE_LINK"
    print -u2 "Installation failed; restored the previous SparkleReleaseKit version."
  else
    /bin/rm -f "$ACTIVE_LINK"
    if (( CREATED_PUBLIC_LINKS == 1 )); then
      /bin/rm -f "$PUBLIC_BINARY" "$PUBLIC_BUNDLE"
    fi
    print -u2 "Installation failed; removed the incomplete first installation."
  fi
}

finish() {
  local status=$?
  trap - EXIT ZERR INT TERM HUP
  if (( status != 0 )); then
    restore_previous || true
  fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    /bin/rm -rf "$STAGE"
  fi
  if (( LOCK_HELD == 1 )); then
    /bin/rm -rf "$LOCK_DIR"
  fi
  exit "$status"
}

trap finish EXIT
trap 'restore_previous' ZERR
trap 'restore_previous; exit 130' INT
trap 'restore_previous; exit 143' TERM
trap 'restore_previous; exit 129' HUP

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

[[ -f "$SOURCE_BINARY" && -x "$SOURCE_BINARY" && ! -L "$SOURCE_BINARY" ]] || {
  print -u2 "The staged sparklekit executable is missing or not executable."
  exit 1
}
[[ -d "$SOURCE_BUNDLE" ]] || {
  print -u2 "The staged SparkleReleaseKit resource bundle is missing."
  exit 1
}

if [[ -L "$INSTALL_DIR" || -L "$MANAGED_ROOT" || -L "$VERSIONS_DIR" ]]; then
  print -u2 "The installation directory and managed storage must not be symbolic links."
  exit 1
fi
/bin/mkdir -p "$INSTALL_DIR" "$VERSIONS_DIR"
/bin/chmod 755 "$INSTALL_DIR" "$MANAGED_ROOT" "$VERSIONS_DIR"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  print -u2 "Another SparkleReleaseKit installation is already in progress."
  exit 1
fi
LOCK_HELD=1
print "$$" > "$LOCK_DIR/pid"
STAGE="$(/usr/bin/mktemp -d "$MANAGED_ROOT/.staging.XXXXXX")"
/bin/cp "$SOURCE_BINARY" "$STAGE/sparklekit"
/bin/cp -R "$SOURCE_BUNDLE" "$STAGE/$BUNDLE_NAME"
/bin/chmod 755 "$STAGE/sparklekit"
fail_at after-stage

STAGED_VERSION="$("$STAGE/sparklekit" version)"
[[ "$STAGED_VERSION" == SparkleReleaseKit\ * ]] || {
  print -u2 "The staged executable did not report a valid SparkleReleaseKit version."
  exit 1
}
[[ -n "$(/usr/bin/find "$STAGE/$BUNDLE_NAME" -mindepth 1 -print -quit)" ]] || {
  print -u2 "The staged resource bundle is empty."
  exit 1
}
[[ -z "$(/usr/bin/find "$STAGE" -type l -print -quit)" ]] || {
  print -u2 "The staged installation must not contain symbolic links."
  exit 1
}
fail_at after-validation

BINARY_SHA="$(/usr/bin/shasum -a 256 "$STAGE/sparklekit" | /usr/bin/awk '{print $1}')"
VERSION_DIR="$VERSIONS_DIR/$BINARY_SHA"
if [[ -e "$VERSION_DIR" ]]; then
  [[ ! -L "$VERSION_DIR" && -d "$VERSION_DIR" && -x "$VERSION_DIR/sparklekit" && -d "$VERSION_DIR/$BUNDLE_NAME" ]] || {
    print -u2 "The existing versioned installation is incomplete."
    exit 1
  }
  [[ "$(/usr/bin/shasum -a 256 "$VERSION_DIR/sparklekit" | /usr/bin/awk '{print $1}')" == "$BINARY_SHA" ]] || {
    print -u2 "The existing versioned executable failed validation."
    exit 1
  }
  /bin/rm -rf "$STAGE"
  STAGE=""
else
  /bin/mv "$STAGE" "$VERSION_DIR"
  STAGE=""
fi
fail_at after-version-install

if [[ -L "$ACTIVE_LINK" ]]; then
  OLD_TARGET="$(/usr/bin/readlink "$ACTIVE_LINK")"
elif [[ -e "$PUBLIC_BINARY" || -e "$PUBLIC_BUNDLE" ]]; then
  [[ ! -L "$PUBLIC_BINARY" && ! -L "$PUBLIC_BUNDLE" && -f "$PUBLIC_BINARY" && -x "$PUBLIC_BINARY" && -d "$PUBLIC_BUNDLE" ]] || {
    print -u2 "The existing installation is incomplete; refusing to replace it."
    exit 1
  }
  LEGACY_SHA="$(/usr/bin/shasum -a 256 "$PUBLIC_BINARY" | /usr/bin/awk '{print $1}')"
  LEGACY_DIR="$VERSIONS_DIR/legacy-$LEGACY_SHA"
  if [[ ! -d "$LEGACY_DIR" ]]; then
    LEGACY_STAGE="$(/usr/bin/mktemp -d "$MANAGED_ROOT/.legacy.XXXXXX")"
    /bin/cp "$PUBLIC_BINARY" "$LEGACY_STAGE/sparklekit"
    /bin/cp -R "$PUBLIC_BUNDLE" "$LEGACY_STAGE/$BUNDLE_NAME"
    /bin/chmod 755 "$LEGACY_STAGE/sparklekit"
    /bin/mv "$LEGACY_STAGE" "$LEGACY_DIR"
  fi
  OLD_TARGET="versions/${LEGACY_DIR:t}"
  replace_link "$OLD_TARGET" "$ACTIVE_LINK"
  /bin/rm -rf "$PUBLIC_BUNDLE"
fi

if [[ ! -L "$PUBLIC_BINARY" || "$(/usr/bin/readlink "$PUBLIC_BINARY" 2>/dev/null || true)" != ".sparklekit/current/sparklekit" ]]; then
  if [[ -e "$PUBLIC_BINARY" && ! -L "$PUBLIC_BINARY" && -z "$OLD_TARGET" ]]; then
    print -u2 "Refusing to replace an unmanaged sparklekit executable."
    exit 1
  fi
  replace_link ".sparklekit/current/sparklekit" "$PUBLIC_BINARY"
  CREATED_PUBLIC_LINKS=1
fi
if [[ ! -L "$PUBLIC_BUNDLE" || "$(/usr/bin/readlink "$PUBLIC_BUNDLE" 2>/dev/null || true)" != ".sparklekit/current/$BUNDLE_NAME" ]]; then
  if [[ -e "$PUBLIC_BUNDLE" && ! -L "$PUBLIC_BUNDLE" && -z "$OLD_TARGET" ]]; then
    print -u2 "Refusing to replace an unmanaged SparkleReleaseKit resource bundle."
    exit 1
  fi
  replace_link ".sparklekit/current/$BUNDLE_NAME" "$PUBLIC_BUNDLE"
  CREATED_PUBLIC_LINKS=1
fi

fail_at before-activate
replace_link "versions/${VERSION_DIR:t}" "$ACTIVE_LINK"
ACTIVATED=1
fail_at after-activate

[[ "$("$PUBLIC_BINARY" version)" == "$STAGED_VERSION" ]] || {
  print -u2 "The activated executable failed post-install validation."
  exit 1
}
[[ -d "$PUBLIC_BUNDLE" ]] || {
  print -u2 "The activated resource bundle failed post-install validation."
  exit 1
}
fail_at after-post-validation
ACTIVATED=0

print "Installed sparklekit to $PUBLIC_BINARY"
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  print "Add this directory to PATH: export PATH=\"$INSTALL_DIR:\$PATH\""
fi
