#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_SPARKLE_VERSION="2.9.4"

usage() {
  cat >&2 <<EOF
usage: $0 --bundle PATH --previous-app PATH
EOF
  return 2
}

die() {
  echo "$*" >&2
  return 1
}

assert_real_file() {
  local path="$1" description="$2"

  [[ -f "$path" && ! -L "$path" ]] || die "$description must be a real file" || return 1
}

assert_real_directory() {
  local path="$1" description="$2"

  [[ -d "$path" && ! -L "$path" ]] || die "$description must be a real directory" || return 1
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

assert_plist_value() {
  local plist_path="$1" key="$2" expected="$3" message="$4" actual

  actual="$(plist_value "$plist_path" "$key" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || die "$message" || return 1
}

bundle_path=""
previous_app=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bundle)
      [[ -z "$bundle_path" && "$#" -ge 2 ]] || usage
      bundle_path="$2"
      shift 2
      ;;
    --previous-app)
      [[ -z "$previous_app" && "$#" -ge 2 ]] || usage
      previous_app="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$bundle_path" && -n "$previous_app" ]] || usage
assert_real_directory "$bundle_path" "qualification bundle"
bundle_path="$(/bin/realpath "$bundle_path")"
assert_real_directory "$previous_app" "previous application"
previous_app="$(/bin/realpath "$previous_app")"

python_executable="${QUALIFY_PYTHON_EXECUTABLE:-/usr/bin/python3}"
sparkle_cli="${QUALIFY_SPARKLE_CLI:-$bundle_path/bin/sparkle}"
runner="${QUALIFY_RUNNER:-}"
verify_script="${QUALIFY_VERIFY_SCRIPT:-$ROOT_DIR/script/verify_update_artifacts.sh}"
version_config="${QUALIFY_VERSION_CONFIG:-$ROOT_DIR/version.env}"
update_config="${QUALIFY_UPDATE_CONFIG:-$ROOT_DIR/config/update.env}"
sparkle_source="${QUALIFY_SPARKLE_SOURCE:-$ROOT_DIR/.build/checkouts/Sparkle}"

assert_real_file "$python_executable" "Python executable"
[[ -x "$python_executable" ]] || die "Python executable must be executable"
assert_real_file "$verify_script" "update artifact verifier"
[[ -x "$verify_script" ]] || die "update artifact verifier must be executable"
assert_real_file "$version_config" "version config"
assert_real_file "$update_config" "update config"
assert_real_directory "$sparkle_source" "Sparkle source"

assert_real_file "$bundle_path/manifest" "qualification manifest"
assert_real_file "$bundle_path/Info.plist" "qualification Info.plist"
assert_real_file "$bundle_path/previous-appcast.xml" "previous signed appcast"
assert_real_directory "$bundle_path/qualification" "qualification directory"
assert_real_directory "$bundle_path/production" "production directory"

archive_name="$(/usr/bin/awk -F= '
  $1 == "archive_name" { count++; value = $2 }
  END { if (count == 1) print value }
' "$bundle_path/manifest")"
[[ "$archive_name" =~ ^CodexRadar-v[0-9]+\.[0-9]+\.[0-9]+-macos-universal\.zip$ ]] ||
  die "qualification manifest has an invalid archive_name"
assert_real_file "$bundle_path/qualification/$archive_name" "qualification archive"
assert_real_file "$bundle_path/qualification/appcast.xml" "qualification signed appcast"

# The CLI is intentionally taken from the artifact, not from PATH. Its framework is
# also part of the pinned distribution and provides the authoritative release version.
assert_real_file "$sparkle_cli" "Sparkle CLI"
[[ -x "$sparkle_cli" ]] || die "Sparkle CLI must be executable"
[[ "$(/bin/realpath "$sparkle_cli")" == "$bundle_path/bin/sparkle" ]] ||
  die "Sparkle CLI must be qualification bundle bin/sparkle"
sparkle_framework_info="$bundle_path/Frameworks/Sparkle.framework/Resources/Info.plist"
assert_real_file "$sparkle_framework_info" "Sparkle CLI framework Info.plist"
assert_plist_value "$sparkle_framework_info" CFBundleShortVersionString "$EXPECTED_SPARKLE_VERSION" \
  "Sparkle CLI version must equal $EXPECTED_SPARKLE_VERSION"

# This performs the manifest hash/length, exact ZIP, signed feed, and relative
# enclosure checks before a local listener or Sparkle process is created.
"$verify_script" --mode artifacts \
  --inputs "$bundle_path" \
  --archive "$bundle_path/qualification/$archive_name" \
  --manifest "$bundle_path/manifest" \
  --final-info-plist "$bundle_path/Info.plist" \
  --version-config "$version_config" \
  --update-config "$update_config" \
  --sparkle-source "$sparkle_source"
"$verify_script" --mode previous \
  --feed "$bundle_path/previous-appcast.xml" \
  --version-config "$version_config" \
  --update-config "$update_config" \
  --sparkle-source "$sparkle_source"

previous_values="$("$python_executable" - "$bundle_path/previous-appcast.xml" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

feed_path = sys.argv[1]
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(feed_path).getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit("previous signed appcast must contain one item")
item = items[0]
version = item.findtext("{%s}shortVersionString" % namespace)
build = item.findtext("{%s}version" % namespace)
if version is None or build is None:
    raise SystemExit("previous signed appcast is missing version metadata")
print("%s %s" % (version, build))
PYTHON
)"
IFS=' ' read -r previous_version previous_build <<<"$previous_values"
[[ "$previous_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$previous_build" =~ ^[1-9][0-9]*$ ]] ||
  die "previous signed appcast has invalid version metadata"

previous_info="$previous_app/Contents/Info.plist"
assert_real_file "$previous_info" "previous application Info.plist"
/usr/bin/plutil -lint "$previous_info" >/dev/null
assert_plist_value "$previous_info" CFBundleIdentifier "com.terence.codex-radar" \
  "previous application bundle identifier does not match"
assert_plist_value "$previous_info" CFBundleShortVersionString "$previous_version" \
  "previous application version is not the immediately previous Production Update"
assert_plist_value "$previous_info" CFBundleVersion "$previous_build" \
  "previous application build is not the immediately previous Production Update"

work_dir=""
server_pid=""
cleanup() {
  local status="$?"

  trap - EXIT INT TERM
  if [[ -n "$server_pid" ]]; then
    /bin/kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ -n "$work_dir" && -d "$work_dir" && ! -L "$work_dir" ]]; then
    /bin/rm -rf "$work_dir"
  fi
  return "$status"
}
handle_interrupt() {
  exit 130
}
handle_termination() {
  exit 143
}
trap cleanup EXIT
trap handle_interrupt INT
trap handle_termination TERM

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-qualify.XXXXXX")"
/bin/chmod 700 "$work_dir"
copied_app="$work_dir/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$copied_app"
assert_real_directory "$copied_app" "copied previous application"

port_path="$work_dir/server-port"
server_log="$work_dir/server.log"
"$python_executable" - "$bundle_path/qualification" >"$port_path" 2>"$server_log" <<'PYTHON' &
import functools
import http.server
import sys

directory = sys.argv[1]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PYTHON
server_pid="$!"

port=""
attempt=0
while [[ "$attempt" -lt 50 ]]; do
  if [[ -s "$port_path" ]]; then
    IFS= read -r port <"$port_path" || true
    break
  fi
  /bin/kill -0 "$server_pid" 2>/dev/null || die "qualification HTTP server exited before binding"
  /bin/sleep 0.1
  attempt=$((attempt + 1))
done
[[ "$port" =~ ^[1-9][0-9]*$ && "$port" -le 65535 ]] ||
  die "qualification HTTP server did not select a valid port"

feed_url="http://127.0.0.1:$port/appcast.xml"
if [[ -n "$runner" ]]; then
  assert_real_file "$runner" "qualification runner"
  [[ -x "$runner" ]] || die "qualification runner must be executable"
  "$runner" "$sparkle_cli" "$copied_app" --application "$copied_app" \
    --check-immediately --feed-url "$feed_url" --interactive --verbose
else
  "$sparkle_cli" "$copied_app" --application "$copied_app" \
    --check-immediately --feed-url "$feed_url" --interactive --verbose
fi

installed_info="$copied_app/Contents/Info.plist"
assert_real_file "$installed_info" "installed application Info.plist"
/usr/bin/plutil -lint "$installed_info" >/dev/null
assert_plist_value "$installed_info" CFBundleIdentifier "com.terence.codex-radar" \
  "installed application bundle identifier does not match"
candidate_version="$(plist_value "$bundle_path/Info.plist" CFBundleShortVersionString)"
candidate_build="$(plist_value "$bundle_path/Info.plist" CFBundleVersion)"
assert_plist_value "$installed_info" CFBundleShortVersionString "$candidate_version" \
  "installed application version does not match qualification bundle"
assert_plist_value "$installed_info" CFBundleVersion "$candidate_build" \
  "installed application build does not match qualification bundle"
for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate \
  SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
  expected_value="$(plist_value "$bundle_path/Info.plist" "$key")"
  assert_plist_value "$installed_info" "$key" "$expected_value" \
    "installed application $key does not match qualification bundle"
done
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction \
  SURequireSignedFeed CodexRadarUpdatesEnabled; do
  assert_plist_value "$installed_info" "$key" true "installed application $key must equal true"
done

printf 'Qualified update to %s (%s)\n' "$candidate_version" "$candidate_build"
