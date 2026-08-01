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

"$CLI" version | /usr/bin/grep -F "SparkleReleaseKit 0.4.0" >/dev/null
help_output="$($CLI help)"
/usr/bin/grep -F "SAFE DEFAULTS" <<<"$help_output" >/dev/null
/usr/bin/grep -F "quickstart" <<<"$help_output" >/dev/null
/usr/bin/grep -F "publish preview" <<<"$help_output" >/dev/null
/usr/bin/grep -F "explain <diagnostic-id>" <<<"$help_output" >/dev/null
/usr/bin/grep -F "verify-update" <<<"$help_output" >/dev/null
/usr/bin/grep -F "free, developer-id, or auto" <<<"$help_output" >/dev/null
/usr/bin/grep -F "update install" <<<"$help_output" >/dev/null
/usr/bin/grep -F "project upgrade" <<<"$help_output" >/dev/null

explain_json="$("$CLI" explain SRK2102 --json)"
EXPLAIN_JSON="$explain_json" /usr/bin/python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["EXPLAIN_JSON"])
required = {
    "schemaVersion",
    "toolVersion",
    "command",
    "success",
    "diagnostics",
    "changes",
    "artifacts",
    "metadata",
}
if set(payload) != required:
    raise SystemExit(f"Unexpected JSON envelope keys: {sorted(payload)}")
if payload["schemaVersion"] != "1.0" or payload["toolVersion"] != "0.4.0":
    raise SystemExit("Unexpected CLI JSON contract version")
if payload["command"] != "explain" or not payload["success"]:
    raise SystemExit("Explain command did not report success")
if payload["metadata"]["id"] != "SRK2102":
    raise SystemExit("Explain metadata does not identify SRK2102")
PY

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/sparklekit-cli.XXXXXX")"
guided_cancel_root="$(mktemp -d "${TMPDIR:-/tmp}/sparklekit-guided-cancel.XXXXXX")"
guided_apply_root="$(mktemp -d "${TMPDIR:-/tmp}/sparklekit-guided-apply.XXXXXX")"
trap '/bin/rm -rf "$fixture_root" "$guided_cancel_root" "$guided_apply_root"' EXIT
FIXTURE_ROOT="$fixture_root" /usr/bin/python3 - <<'PY'
import os
import plistlib
from pathlib import Path

root = Path(os.environ["FIXTURE_ROOT"])
project = root / "Example App.xcodeproj"
schemes = project / "xcshareddata" / "xcschemes"
sources = root / "Example App"
schemes.mkdir(parents=True)
sources.mkdir(parents=True)
(project / "project.pbxproj").write_text(
    """
    PRODUCT_NAME = "Example App";
    PRODUCT_BUNDLE_IDENTIFIER = com.example.app;
    INFOPLIST_FILE = "Example App/Info.plist";
    repositoryURL = "https://github.com/sparkle-project/Sparkle";
    productName = Sparkle;
    """,
    encoding="utf-8",
)
(schemes / "Example App.xcscheme").write_text(
    "<Scheme></Scheme>",
    encoding="utf-8",
)
(sources / "ExampleApp.swift").write_text(
    'import SwiftUI\n@main struct ExampleApp: App { var body: some Scene { WindowGroup { Text("Hello") } } }\n',
    encoding="utf-8",
)
with (sources / "Info.plist").open("wb") as stream:
    plistlib.dump(
        {
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example App",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        },
        stream,
    )
PY

/bin/cp -R "$fixture_root/." "$guided_cancel_root/"
/bin/cp -R "$fixture_root/." "$guided_apply_root/"
GUIDED_CANCEL_ROOT="$guided_cancel_root" /usr/bin/python3 - <<'PY'
import os
from pathlib import Path

schemes = (
    Path(os.environ["GUIDED_CANCEL_ROOT"])
    / "Example App.xcodeproj"
    / "xcshareddata"
    / "xcschemes"
)
(schemes / "Beta.xcscheme").write_text(
    "<Scheme></Scheme>",
    encoding="utf-8",
)
PY

public_key="BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="

run_guided_session() {
  local project_root="$1"
  local scenario="$2"
  CLI_PATH="$CLI" PROJECT_ROOT="$project_root" SCENARIO="$scenario" PUBLIC_KEY="$public_key" \
    /usr/bin/python3 - <<'PY'
import errno
import os
import pty
import select
import subprocess
import time

scenario = os.environ["SCENARIO"]
responses = {
    "cancel": ["", "1", "q"],
    "apply": ["", "u", "", "n", "y"],
}[scenario]
command = [
    os.environ["CLI_PATH"],
    "quickstart",
    os.environ["PROJECT_ROOT"],
    "--owner",
    "example",
    "--repo",
    "example-app",
    "--public-key",
    os.environ["PUBLIC_KEY"],
    "--with-workflow",
]
environment = dict(os.environ)
environment["NO_COLOR"] = "1"
master, slave = pty.openpty()
process = subprocess.Popen(
    command,
    stdin=slave,
    stdout=slave,
    stderr=slave,
    close_fds=True,
    env=environment,
)
os.close(slave)
os.write(master, "".join(f"{response}\n" for response in responses).encode())
chunks = []
deadline = time.monotonic() + 20
while True:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        process.kill()
        process.wait()
        raise SystemExit("Guided CLI session timed out")
    readable, _, _ = select.select([master], [], [], min(0.1, remaining))
    if readable:
        try:
            chunk = os.read(master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            chunk = b""
        if chunk:
            chunks.append(chunk)
    if process.poll() is not None:
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            chunks.append(chunk)
        break
os.close(master)
output = b"".join(chunks).decode("utf-8", errors="replace").replace("\r", "\n")
if process.returncode != 0:
    raise SystemExit(
        f"Guided CLI session exited with {process.returncode}\n{output}"
    )
print(output)
PY
}

guided_cancel_output="$(run_guided_session "$guided_cancel_root" cancel)"
/usr/bin/grep -F "[1/7] Inspecting Xcode project" <<<"$guided_cancel_output" >/dev/null
/usr/bin/grep -F "Multiple shared schemes were found." <<<"$guided_cancel_output" >/dev/null
/usr/bin/grep -F "Choose the shared scheme" <<<"$guided_cancel_output" >/dev/null
/usr/bin/grep -F "Cancelled before approval; no files were changed." <<<"$guided_cancel_output" >/dev/null
[[ ! -e "$guided_cancel_root/sparklekit.json" ]]
[[ ! -e "$guided_cancel_root/SparkleReleaseKit" ]]

guided_apply_output="$(run_guided_session "$guided_apply_root" apply)"
/usr/bin/grep -F "Use this selection?" <<<"$guided_apply_output" >/dev/null
/usr/bin/grep -F "Apply these changes? [y/N]" <<<"$guided_apply_output" >/dev/null
/usr/bin/grep -F "Files changed: Yes" <<<"$guided_apply_output" >/dev/null
/usr/bin/grep -F "A real update, signature, appcast, or release build was not verified" <<<"$guided_apply_output" >/dev/null
[[ -f "$guided_apply_root/sparklekit.json" ]]
[[ -f "$guided_apply_root/SparkleReleaseKit/AppUpdater.swift" ]]
[[ -f "$guided_apply_root/SparkleReleaseKit/INTEGRATION.md" ]]
[[ -f "$guided_apply_root/.github/workflows/sparkle-release.yml" ]]

setup_arguments=(
  quickstart "$fixture_root"
  --non-interactive
  --owner example
  --repo example-app
  --public-key "$public_key"
  --with-workflow
  --json
)
preview_json="$("$CLI" "${setup_arguments[@]}")"
[[ ! -e "$fixture_root/sparklekit.json" ]]
PREVIEW_JSON="$preview_json" /usr/bin/python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["PREVIEW_JSON"])
if not payload["success"] or payload["command"] != "quickstart":
    raise SystemExit("Quickstart preview did not succeed")
if payload["metadata"]["integration"]["applied"]:
    raise SystemExit("Quickstart preview unexpectedly applied changes")
if not any(change["kind"] == "create" for change in payload["changes"]):
    raise SystemExit("Quickstart preview did not report planned files")
PY

apply_json="$("$CLI" "${setup_arguments[@]}" --apply)"
[[ -f "$fixture_root/sparklekit.json" ]]
[[ -f "$fixture_root/SparkleReleaseKit/AppUpdater.swift" ]]
[[ -f "$fixture_root/SparkleReleaseKit/INTEGRATION.md" ]]
[[ -f "$fixture_root/.github/workflows/sparkle-release.yml" ]]
APPLY_JSON="$apply_json" /usr/bin/python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["APPLY_JSON"])
if not payload["success"] or not payload["metadata"]["integration"]["applied"]:
    raise SystemExit("Quickstart apply did not report applied changes")
PY

/bin/rm "$fixture_root/SparkleReleaseKit/AppUpdater.swift"
doctor_preview="$("$CLI" doctor "$fixture_root" --fix --json)"
[[ ! -e "$fixture_root/SparkleReleaseKit/AppUpdater.swift" ]]
DOCTOR_JSON="$doctor_preview" /usr/bin/python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["DOCTOR_JSON"])
if not payload["success"] or payload["metadata"]["applied"]:
    raise SystemExit("Doctor fix preview did not remain read-only")
if not any(
    change["relativePath"] == "SparkleReleaseKit/AppUpdater.swift"
    and change["kind"] == "create"
    for change in payload["changes"]
):
    raise SystemExit("Doctor fix preview did not plan the missing updater")
PY

doctor_apply="$("$CLI" doctor "$fixture_root" --fix --apply --json)"
[[ -f "$fixture_root/SparkleReleaseKit/AppUpdater.swift" ]]
DOCTOR_JSON="$doctor_apply" /usr/bin/python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["DOCTOR_JSON"])
if not payload["success"] or not payload["metadata"]["applied"]:
    raise SystemExit("Doctor fix apply did not restore the missing updater")
PY

doctor_human="$("$CLI" doctor "$fixture_root")"
/usr/bin/grep -F "[1/1] Running passive doctor checks" <<<"$doctor_human" >/dev/null
/usr/bin/grep -F "[PASS]" <<<"$doctor_human" >/dev/null
if [[ "$doctor_human" == *$'\r'* || "$doctor_human" == *$'\033'* ]]; then
  echo "Plain doctor output contains terminal control characters" >&2
  exit 1
fi

upgrade_preview="$("$CLI" project upgrade "$fixture_root" --json)"
UPGRADE_JSON="$upgrade_preview" /usr/bin/python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["UPGRADE_JSON"])
if payload["command"] != "project upgrade" or not payload["success"]:
    raise SystemExit("Project upgrade preview did not succeed")
if payload["metadata"]["applied"]:
    raise SystemExit("Project upgrade preview unexpectedly wrote files")
if payload["metadata"]["conflicts"]:
    raise SystemExit("Unmodified integration unexpectedly has conflicts")
PY

expect_usage_error "unknown option" doctor --jsno
expect_usage_error "missing option value" setup --owner
expect_usage_error "duplicate option" setup --owner example --owner duplicate
expect_usage_error "extra positional" validate-feed one.xml two.xml
expect_usage_error "invalid release mode" verify missing.zip --release-mode paid-only
expect_usage_error "missing appcast" verify-update missing.zip --version 1
expect_usage_error "unknown update subcommand" update unexpected

echo "CLI contract checks passed."
