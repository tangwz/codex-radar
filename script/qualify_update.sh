#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_SPARKLE_REVISION="b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
EXPECTED_TOOLS_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
TOOLS_URL="https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz"
PRODUCTION_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"
TEST_HARNESS=false

die() { echo "$*" >&2; return 1; }
usage() { echo "usage: $0 --bundle PATH --previous-app PATH [--tools-archive PATH]" >&2; return 2; }
real_file() { [[ -f "$1" && ! -L "$1" ]] || die "$2 must be a real file"; }
real_dir() { [[ -d "$1" && ! -L "$1" ]] || die "$2 must be a real directory"; }
plist() { /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null; }
assert_plist() { [[ "$(plist "$1" "$2" 2>/dev/null || true)" == "$3" ]] || die "$4"; }

bundle="" previous_app="" tools_archive=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --bundle) [[ -z "$bundle" && "$#" -ge 2 ]] || usage; bundle="$2"; shift 2 ;;
    --previous-app) [[ -z "$previous_app" && "$#" -ge 2 ]] || usage; previous_app="$2"; shift 2 ;;
    --tools-archive) [[ -z "$tools_archive" && "$#" -ge 2 ]] || usage; tools_archive="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$bundle" && -n "$previous_app" ]] || usage
if [[ "$TEST_HARNESS" != true ]]; then
  if /usr/bin/env | /usr/bin/awk -F= '$1 ~ /^QUALIFY_/' | /usr/bin/grep . >/dev/null; then
    die "QUALIFY_* overrides are only available in the test harness"
  fi
fi
real_dir "$bundle" "qualification bundle"; bundle="$(/bin/realpath "$bundle")"
real_dir "$previous_app" "previous application"; previous_app="$(/bin/realpath "$previous_app")"

python="${QUALIFY_PYTHON_EXECUTABLE:-/usr/bin/python3}"
verify="${QUALIFY_VERIFY_SCRIPT:-$ROOT_DIR/script/verify_update_artifacts.sh}"
version_config="${QUALIFY_VERSION_CONFIG:-$ROOT_DIR/version.env}"
update_config="${QUALIFY_UPDATE_CONFIG:-$ROOT_DIR/config/update.env}"
sparkle_checkout="${QUALIFY_SPARKLE_SOURCE:-$ROOT_DIR/.build/checkouts/Sparkle}"
fetch="${QUALIFY_FETCH_EXECUTABLE:-}"
runner="${QUALIFY_RUNNER:-}"
real_file "$python" "Python executable"; [[ -x "$python" ]] || die "Python executable must be executable"
real_file "$verify" "update artifact verifier"; [[ -x "$verify" ]] || die "update artifact verifier must be executable"
real_file "$version_config" "version config"; real_file "$update_config" "update config"
real_dir "$sparkle_checkout" "Sparkle source"

work="" server_pid="" stop_file=""
cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  if [[ -n "$stop_file" ]]; then : >"$stop_file"; fi
  if [[ -n "$server_pid" ]]; then wait "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$work" && -d "$work" && ! -L "$work" ]]; then /bin/rm -rf "$work"; fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-qualify.XXXXXX")"; /bin/chmod 700 "$work"

# Keep the source bundle out of every later trust decision. The verifier runs again
# on this private, immutable-at-use snapshot.
snapshot="$work/inputs"
/usr/bin/ditto "$bundle" "$snapshot"
real_file "$snapshot/manifest" "qualification manifest"
archive_name="$(/usr/bin/awk -F= '$1 == "archive_name" { n++; v=$2 } END { if (n == 1) print v }' "$snapshot/manifest")"
[[ "$archive_name" =~ ^CodexRadar-v[0-9]+\.[0-9]+\.[0-9]+-macos-universal\.zip$ ]] || die "qualification manifest has an invalid archive_name"
"$verify" --mode artifacts --inputs "$snapshot" --archive "$snapshot/qualification/$archive_name" \
  --manifest "$snapshot/manifest" --final-info-plist "$snapshot/Info.plist" \
  --version-config "$version_config" --update-config "$update_config" --sparkle-source "$sparkle_checkout"
"$verify" --mode previous --feed "$snapshot/previous-appcast.xml" --version-config "$version_config" \
  --update-config "$update_config" --sparkle-source "$sparkle_checkout"

current_feed="$work/current-production-feed.xml"
if [[ -n "$fetch" ]]; then
  real_file "$fetch" "Production Feed fetch executable"; [[ -x "$fetch" ]] || die "Production Feed fetch executable must be executable"
  "$fetch" "$PRODUCTION_FEED_URL" "$current_feed"
else
  /usr/bin/curl --fail --location --silent --show-error --proto '=https' "$PRODUCTION_FEED_URL" --output "$current_feed"
fi
"$verify" --mode previous --feed "$current_feed" --version-config "$version_config" \
  --update-config "$update_config" --sparkle-source "$sparkle_checkout"
/usr/bin/cmp -s "$current_feed" "$snapshot/previous-appcast.xml" ||
  die "bundled previous Production Feed is stale"

read -r previous_version previous_build <<EOF
$("$python" - "$current_feed" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
item, = root.findall('./channel/item')
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
print(item.findtext('{%s}shortVersionString' % ns), item.findtext('{%s}version' % ns))
PYTHON
)
EOF
[[ "$previous_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$previous_build" =~ ^[1-9][0-9]*$ ]] || die "current Production Feed has invalid version metadata"

tree_manifest() {
  "$python" - "$1" "$2" <<'PYTHON'
import hashlib, os, stat, sys
root, output = map(os.path.realpath, sys.argv[1:])
if not os.path.isdir(root): raise SystemExit('application root is not a directory')
records = []
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    names = sorted(dirs + files, key=os.fsencode)
    dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(base, name))]
    for name in names:
        path = os.path.join(base, name); rel = os.path.relpath(path, root)
        st = os.lstat(path); mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            target = os.readlink(path); resolved = os.path.realpath(path)
            if not os.path.exists(resolved) or os.path.commonpath((root, resolved)) != root:
                raise SystemExit('application contains an unresolved or escaping symlink: ' + rel)
            records.append((os.fsencode(rel), b'L', str(mode).encode(), os.fsencode(target)))
        elif stat.S_ISREG(st.st_mode):
            digest = hashlib.sha256()
            with open(path, 'rb') as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b''): digest.update(chunk)
            records.append((os.fsencode(rel), b'F', str(mode).encode(), digest.hexdigest().encode()))
        elif stat.S_ISDIR(st.st_mode): records.append((os.fsencode(rel), b'D', str(mode).encode(), b''))
        else: raise SystemExit('application contains an unsupported file type: ' + rel)
with open(output, 'wb') as handle:
    for record in sorted(records): handle.write(b'\0'.join(record) + b'\0')
PYTHON
}
source_tree="$work/source-tree.manifest"; copied_tree="$work/copied-tree.manifest"; source_after="$work/source-after.manifest"
tree_manifest "$previous_app" "$source_tree"
source_identity="$(/usr/bin/stat -f '%d:%i' "$previous_app")"
previous_info="$previous_app/Contents/Info.plist"; real_file "$previous_info" "previous application Info.plist"
assert_plist "$previous_info" CFBundleIdentifier com.terence.codex-radar "previous application bundle identifier does not match"
assert_plist "$previous_info" CFBundleShortVersionString "$previous_version" "previous application version is not the immediately previous Production Update"
assert_plist "$previous_info" CFBundleVersion "$previous_build" "previous application build is not the immediately previous Production Update"

copied_app="$work/CodexRadar.app"; /usr/bin/ditto "$previous_app" "$copied_app"
[[ "$source_identity" == "$(/usr/bin/stat -f '%d:%i' "$previous_app")" ]] || die "previous application directory changed while being copied"
tree_manifest "$previous_app" "$source_after"; /usr/bin/cmp -s "$source_tree" "$source_after" || die "previous application changed while being copied"
tree_manifest "$copied_app" "$copied_tree"; /usr/bin/cmp -s "$source_tree" "$copied_tree" || die "copied previous application differs from source"
copied_info="$copied_app/Contents/Info.plist"; real_file "$copied_info" "copied previous application Info.plist"
assert_plist "$copied_info" CFBundleShortVersionString "$previous_version" "copied previous application version is not the immediately previous Production Update"
assert_plist "$copied_info" CFBundleVersion "$previous_build" "copied previous application build is not the immediately previous Production Update"

tools="$work/sparkle-tools"; /bin/mkdir -m 700 "$tools"
archive="$work/Sparkle-2.9.4.tar.xz"
if [[ -n "$tools_archive" ]]; then real_file "$tools_archive" "Sparkle tools archive"; /bin/cp "$tools_archive" "$archive"; else /usr/bin/curl --fail --location --silent --show-error --proto '=https' "$TOOLS_URL" --output "$archive"; fi
[[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" == "$EXPECTED_TOOLS_SHA256" ]] || die "Sparkle tools archive SHA-256 does not match 2.9.4"
"$python" - "$archive" "$tools" <<'PYTHON'
import os, sys, tarfile
archive, destination = sys.argv[1:]
with tarfile.open(archive, 'r:xz') as source:
    for member in source.getmembers():
        name = member.name
        while name.startswith('./'): name = name[2:]
        if not name or name == '.': continue
        parts = name.split('/')
        if member.name.startswith('/') or any(part in ('', '.', '..') for part in parts): raise SystemExit('unsafe Sparkle tools archive path')
    source.extractall(destination)
PYTHON

# Sparkle 2.9.4's public tools archive is provenance evidence only: it deliberately
# lacks sparkle-cli. The executable is rebuilt from an isolated git archive of the
# exact source commit, never from the bundle or a mutable checkout.
[[ "$(/usr/bin/git -C "$sparkle_checkout" rev-parse HEAD)" == "$EXPECTED_SPARKLE_REVISION" ]] || die "Sparkle source revision must equal $EXPECTED_SPARKLE_REVISION"
source_tree_dir="$work/sparkle-source"; /bin/mkdir -m 700 "$source_tree_dir"
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/git -C "$sparkle_checkout" archive "$EXPECTED_SPARKLE_REVISION" | /usr/bin/tar -x -C "$source_tree_dir"
[[ "$(/usr/bin/git -C "$sparkle_checkout" rev-parse "$EXPECTED_SPARKLE_REVISION^{tree}")" == "$(/usr/bin/git -C "$sparkle_checkout" rev-parse HEAD^{tree})" ]] || die "Sparkle source tree does not match pinned revision"
cli="$work/sparkle-cli"
if [[ "$TEST_HARNESS" == true && -n "${QUALIFY_TEST_CLI:-}" ]]; then
  real_file "$QUALIFY_TEST_CLI" "test Sparkle CLI"; /bin/cp "$QUALIFY_TEST_CLI" "$cli"; /bin/chmod 755 "$cli"
else
  /bin/mkdir -m 700 "$work/home" "$work/tmp"
  /usr/bin/env -i PATH=/usr/bin:/bin HOME="$work/home" TMPDIR="$work/tmp" SWIFTPM_DISABLE_SANDBOX=1 \
    /usr/bin/xcodebuild -disableAutomaticPackageResolution -project "$source_tree_dir/Sparkle.xcodeproj" -scheme sparkle-cli -configuration Release \
    SYMROOT="$work/build" OBJROOT="$work/obj" CODE_SIGNING_ALLOWED=NO build >/dev/null
  built_cli="$work/build/Release/sparkle.app/Contents/MacOS/sparkle"
  built_info="$work/build/Release/sparkle.app/Contents/Info.plist"
  real_file "$built_cli" "built Sparkle CLI executable"
  real_file "$built_info" "built Sparkle CLI Info.plist"
  assert_plist "$built_info" CFBundleShortVersionString "$EXPECTED_SPARKLE_VERSION" "built Sparkle CLI version must equal $EXPECTED_SPARKLE_VERSION"
  /usr/bin/file "$built_cli" | /usr/bin/grep -F 'Mach-O' >/dev/null || die "built Sparkle CLI must be Mach-O"
  /bin/cp "$built_cli" "$cli"; /bin/chmod 755 "$cli"
fi
real_file "$cli" "verified Sparkle CLI"; [[ -x "$cli" ]] || die "verified Sparkle CLI must be executable"

stop_file="$work/server.stop"; port_file="$work/server.port"; server_log="$work/server.log"
"$python" - "$snapshot/qualification" "$stop_file" "$port_file" >"$server_log" 2>&1 <<'PYTHON' &
import functools, http.server, os, sys
directory, stop, port_file = sys.argv[1:]
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory))
server.timeout = .1
with open(port_file, 'w') as handle: handle.write(str(server.server_address[1]))
while not os.path.exists(stop): server.handle_request()
server.server_close()
PYTHON
server_pid="$!"; [[ -n "${QUALIFY_TEST_SERVER_PID_FILE:-}" ]] && printf '%s\n' "$server_pid" >"$QUALIFY_TEST_SERVER_PID_FILE"
port=""; for attempt in {1..50}; do [[ -s "$port_file" ]] && { IFS= read -r port <"$port_file" || true; break; }; /bin/sleep .1; done
[[ "$port" =~ ^[1-9][0-9]*$ && "$port" -le 65535 ]] || die "qualification HTTP server did not select a valid port"
/bin/kill -0 "$server_pid" 2>/dev/null || die "qualification HTTP server exited after publishing its port"
feed_url="http://127.0.0.1:$port/appcast.xml"
if [[ -n "$runner" ]]; then "$runner" "$cli" "$copied_app" --application "$copied_app" --check-immediately --feed-url "$feed_url" --interactive --verbose; else "$cli" "$copied_app" --application "$copied_app" --check-immediately --feed-url "$feed_url" --interactive --verbose; fi
/bin/kill -0 "$server_pid" 2>/dev/null || die "qualification HTTP server exited during Sparkle execution"

for key in CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
  assert_plist "$copied_info" "$key" "$(plist "$snapshot/Info.plist" "$key")" "installed application $key does not match qualification bundle"
done
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do assert_plist "$copied_info" "$key" true "installed application $key must equal true"; done
printf 'Qualified update to %s (%s)\n' "$(plist "$copied_info" CFBundleShortVersionString)" "$(plist "$copied_info" CFBundleVersion)"
