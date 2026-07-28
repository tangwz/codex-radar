#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/script/package_app.sh"
SIGN_SCRIPT="$ROOT_DIR/script/sign_app.sh"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_app.sh"
RELEASE_SCRIPT="$ROOT_DIR/script/package_release.sh"
source "$ROOT_DIR/script/lib/release_common.sh"
load_version_config "$ROOT_DIR/version.env"
CURRENT_MARKETING_VERSION="$MARKETING_VERSION"
CURRENT_BUILD_NUMBER="$BUILD_NUMBER"
CURRENT_RELEASE_BASENAME="$(release_asset_basename)"

fail() {
  echo "$*" >&2
  exit 1
}

[[ -f "$PACKAGE_SCRIPT" ]] || fail "package_app.sh does not exist"
[[ -f "$SIGN_SCRIPT" ]] || fail "sign_app.sh does not exist"
[[ -f "$VERIFY_SCRIPT" ]] || fail "verify_app.sh does not exist"
[[ -f "$RELEASE_SCRIPT" ]] || fail "package_release.sh does not exist"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
swift package dump-package >"$fixture_dir/base-package-dump.json"

atomic_swap_compat_source="$fixture_dir/atomic-swap-without-resolve-beneath.c"
/usr/bin/sed '/^#include <unistd.h>$/a\
#undef RENAME_RESOLVE_BENEATH
' "$ROOT_DIR/script/helpers/atomic_swap.c" >"$atomic_swap_compat_source"
/usr/bin/xcrun --sdk macosx clang -fsyntax-only \
  -mmacosx-version-min=14.0 "$atomic_swap_compat_source"

setup_fixture() {
  local name="$1" fixture_root="$fixture_dir/$1"

  mkdir -p "$fixture_root/script/lib" "$fixture_root/config" "$fixture_root/Tests" "$fixture_root/bin"
  cp "$PACKAGE_SCRIPT" "$fixture_root/script/package_app.sh"
  cp "$ROOT_DIR/script/lib/release_common.sh" "$fixture_root/script/lib/release_common.sh"
  cp "$ROOT_DIR/Package.swift" "$ROOT_DIR/Package.resolved" "$fixture_root/"
  cp "$fixture_dir/base-package-dump.json" "$fixture_root/Package.dump.json"
  if [[ -f "$ROOT_DIR/script/helpers/atomic_swap.c" ]]; then
    mkdir -p "$fixture_root/script/helpers"
    cp "$ROOT_DIR/script/helpers/atomic_swap.c" "$fixture_root/script/helpers/atomic_swap.c"
  fi
  printf 'MARKETING_VERSION=0.1.0\nBUILD_NUMBER=1\n' >"$fixture_root/version.env"
  printf '%s\n' "$fixture_root"
}

write_update_config() {
  local fixture_root="$1" sparkle_version="$2" public_key="$3"

  printf '%s\n' \
    "SPARKLE_VERSION=$sparkle_version" \
    "SPARKLE_PUBLIC_ED_KEY=$public_key" \
    "PRODUCTION_FEED_URL=https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml" \
    >"$fixture_root/config/update.env"
}

install_mock_swift() {
  local fixture_root="$1"

  cat >"$fixture_root/bin/swift" <<'MOCK_SWIFT'
#!/usr/bin/env bash
set -euo pipefail

scratch_path=""
target_triple=""
show_bin_path=false
package_path=""
if [[ "${1:-}" == package ]]; then
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --package-path)
        package_path="$2"
        shift 2
        ;;
      dump-package)
        cat "$package_path/Package.dump.json"
        exit 0
        ;;
      *) shift ;;
    esac
  done
  exit 2
fi

automatic_resolution_disabled=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --scratch-path)
      scratch_path="$2"
      shift 2
      ;;
    --triple)
      target_triple="$2"
      shift 2
      ;;
    --show-bin-path)
      show_bin_path=true
      shift
      ;;
    --disable-automatic-resolution)
      automatic_resolution_disabled=true
      shift
      ;;
    *) shift ;;
  esac
done

[[ -n "$scratch_path" && -n "$target_triple" ]]
[[ "$automatic_resolution_disabled" == true ]] || {
  echo "swift build did not disable automatic resolution" >&2
  exit 1
}
architecture="${target_triple%%-*}"
bin_path="$scratch_path/products"
if [[ "$show_bin_path" == true ]]; then
  printf '%s\n' "$bin_path"
  exit 0
fi

resource_bundle="$bin_path/CodexRadar_CodexRadar.bundle"
mkdir -p "$resource_bundle/en.lproj" "$resource_bundle/zh-hans.lproj"
binary_architecture="$architecture"
if [[ "${PACKAGE_TEST_WRONG_INPUT_SLICE:-false}" == true && "$architecture" == arm64 ]]; then
  binary_architecture=x86_64
fi
printf 'ARCHS=%s\n' "$binary_architecture" >"$bin_path/CodexRadar"
chmod +x "$bin_path/CodexRadar"
printf 'shared resource\n' >"$resource_bundle/en.lproj/Localizable.strings"
printf 'shared resource\n' >"$resource_bundle/zh-hans.lproj/Localizable.strings"
if [[ "${PACKAGE_TEST_RESOURCE_MISMATCH:-false}" == true && "$architecture" == x86_64 ]]; then
  printf 'different resource\n' >"$resource_bundle/x86-only.txt"
fi
if [[ "${PACKAGE_TEST_SPECIAL_RESOURCE_NAMES:-false}" == true ]]; then
  if [[ "$architecture" == arm64 ]]; then
    printf 'same content\n' >"$resource_bundle/newline
name.txt"
  else
    printf 'same content\n' >"$resource_bundle/newline	name.txt"
  fi
fi

framework="$bin_path/Sparkle.framework"
mkdir -p "$framework/Versions/B/Resources"
/usr/bin/plutil -create xml1 "$framework/Versions/B/Resources/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 2.9.4 "$framework/Versions/B/Resources/Info.plist"
ln -s B "$framework/Versions/Current"
ln -s Versions/Current/Resources "$framework/Resources"
if [[ "${PACKAGE_TEST_ESCAPED_NEWLINE_SYMLINK:-false}" == true && "$architecture" == arm64 ]]; then
  ln -s /tmp "$framework/escaped
link"
fi
MOCK_SWIFT
  chmod +x "$fixture_root/bin/swift"

  cat >"$fixture_root/bin/lipo" <<'MOCK_LIPO'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == -archs ]]; then
  sed -n 's/^ARCHS=//p' "$2"
  exit 0
fi

[[ "$1" == -create ]]
shift
inputs=()
output=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -output)
      output="$2"
      shift 2
      ;;
    *)
      inputs+=("$1")
      shift
      ;;
  esac
done
if [[ "${PACKAGE_TEST_WRONG_MERGED_RESULT:-false}" == true ]]; then
  printf 'ARCHS=arm64\n' >"$output"
else
  archs=""
  for input in "${inputs[@]}"; do
    input_archs="$(sed -n 's/^ARCHS=//p' "$input")"
    archs="${archs:+$archs }$input_archs"
  done
  printf 'ARCHS=%s\n' "$archs" >"$output"
fi
MOCK_LIPO
  chmod +x "$fixture_root/bin/lipo"

  cat >"$fixture_root/bin/otool" <<'MOCK_OTOOL'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == -arch ]]
architecture="$2"
if [[ "${PACKAGE_TEST_MISSING_RPATH_ARCH:-}" == "$architecture" ]]; then
  printf 'Load command 0\n      cmd LC_SEGMENT_64\n'
else
  printf 'Load command 0\n          cmd LC_RPATH\n      cmdsize 48\n         path @executable_path/../Frameworks (offset 12)\n'
fi
MOCK_OTOOL
  chmod +x "$fixture_root/bin/otool"
}

assert_rejected() {
  local expected_message="$1" fixture_root="$2" resolved_before resolved_after
  shift 2

  resolved_before="$(shasum -a 256 "$fixture_root/Package.resolved" | awk '{print $1}')"
  if [[ -x "$fixture_root/bin/lipo" ]]; then
    package_command=(env \
      PATH="$fixture_root/bin:$PATH" \
      PACKAGE_APP_LIPO_EXECUTABLE="$fixture_root/bin/lipo" \
      PACKAGE_APP_OTOOL_EXECUTABLE="$fixture_root/bin/otool" \
      "$fixture_root/script/package_app.sh")
  else
    package_command=(env PATH="$fixture_root/bin:$PATH" "$fixture_root/script/package_app.sh")
  fi
  if output="$("${package_command[@]}" "$@" 2>&1)"; then
    fail "package fixture unexpectedly succeeded: $expected_message"
  fi
  resolved_after="$(shasum -a 256 "$fixture_root/Package.resolved" | awk '{print $1}')"
  [[ "$resolved_after" == "$resolved_before" ]] || fail "package fixture changed Package.resolved"
  [[ "$output" == *"$expected_message"* ]] || {
    echo "$output" >&2
    fail "package fixture did not report: $expected_message"
  }
}

assert_succeeds() {
  local fixture_root="$1" resolved_before resolved_after
  shift

  resolved_before="$(shasum -a 256 "$fixture_root/Package.resolved" | awk '{print $1}')"
  output="$(env \
    PATH="$fixture_root/bin:$PATH" \
    PACKAGE_APP_LIPO_EXECUTABLE="$fixture_root/bin/lipo" \
    PACKAGE_APP_OTOOL_EXECUTABLE="$fixture_root/bin/otool" \
    "$fixture_root/script/package_app.sh" "$@" 2>&1)" || {
      echo "$output" >&2
      fail "package fixture unexpectedly failed"
    }
  resolved_after="$(shasum -a 256 "$fixture_root/Package.resolved" | awk '{print $1}')"
  [[ "$resolved_after" == "$resolved_before" ]] || fail "successful package fixture changed Package.resolved"
}

start_paused_package() {
  local fixture_root="$1" phase="$2" control_dir

  control_dir="$fixture_root/test-control-$phase"

  mkdir -m 700 -p "$fixture_root/tmp" "$control_dir"
  background_log="$control_dir/package.log"
  background_continue="$control_dir/continue"
  env \
    PATH="$fixture_root/bin:$PATH" \
    TMPDIR="$fixture_root/tmp" \
    PACKAGE_APP_LIPO_EXECUTABLE="$fixture_root/bin/lipo" \
    PACKAGE_APP_OTOOL_EXECUTABLE="$fixture_root/bin/otool" \
    PACKAGE_APP_TEST_CONTROL_DIR="$control_dir" \
    PACKAGE_APP_TEST_PAUSE_PHASE="$phase" \
    "$fixture_root/script/package_app.sh" \
      --output "$fixture_root/dist" --configuration debug \
      --architectures arm64 --updates-enabled false \
      >"$background_log" 2>&1 &
  background_pid=$!

  local attempt=0
  while [[ ! -f "$control_dir/ready" && "$attempt" -lt 1000 ]]; do
    if ! kill -0 "$background_pid" 2>/dev/null; then
      wait "$background_pid" || true
      cat "$background_log" >&2
      fail "package fixture exited before $phase pause"
    fi
    sleep 0.01
    attempt=$((attempt + 1))
  done
  if [[ ! -f "$control_dir/ready" ]]; then
    kill -TERM "$background_pid" 2>/dev/null || true
    wait "$background_pid" || true
    fail "package fixture timed out before $phase pause"
  fi
}

finish_paused_rejection() {
  local expected_message="$1" output

  : >"$background_continue"
  if wait "$background_pid"; then
    fail "paused package fixture unexpectedly succeeded: $expected_message"
  fi
  output="$(cat "$background_log")"
  [[ "$output" == *"$expected_message"* ]] || {
    echo "$output" >&2
    fail "paused package fixture did not report: $expected_message"
  }
}

architecture_fixture="$(setup_fixture architectures)"
write_update_config "$architecture_fixture" "2.9.4" ""
assert_rejected "duplicate architecture: arm64" "$architecture_fixture" \
  --output "$architecture_fixture/dist" --configuration debug \
  --architectures "arm64 arm64" --updates-enabled false
assert_rejected "unknown architecture: ppc64" "$architecture_fixture" \
  --output "$architecture_fixture/dist" --configuration debug \
  --architectures "arm64 ppc64" --updates-enabled false

key_fixture="$(setup_fixture missing-key)"
write_update_config "$key_fixture" "2.9.4" ""
assert_rejected "invalid SPARKLE_PUBLIC_ED_KEY" "$key_fixture" \
  --output "$key_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true

version_fixture="$(setup_fixture wrong-sparkle-version)"
write_update_config "$version_fixture" "2.9.3" ""
assert_rejected "SPARKLE_VERSION must equal 2.9.4" "$version_fixture" \
  --output "$version_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false

wrong_url_fixture="$(setup_fixture wrong-sparkle-url)"
write_update_config "$wrong_url_fixture" "2.9.4" ""
install_mock_swift "$wrong_url_fixture"
/usr/bin/plutil -replace dependencies.0.sourceControl.0.location.remote.0.urlString \
  -string "https://example.com/Sparkle" "$wrong_url_fixture/Package.dump.json"
assert_rejected "Package.swift must contain exactly one official Sparkle dependency" "$wrong_url_fixture" \
  --output "$wrong_url_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false

non_exact_fixture="$(setup_fixture non-exact-sparkle)"
write_update_config "$non_exact_fixture" "2.9.4" ""
install_mock_swift "$non_exact_fixture"
/usr/bin/plutil -remove dependencies.0.sourceControl.0.requirement.exact "$non_exact_fixture/Package.dump.json"
/usr/bin/plutil -insert dependencies.0.sourceControl.0.requirement.range -json '["2.9.4","3.0.0"]' \
  "$non_exact_fixture/Package.dump.json"
assert_rejected "Sparkle dependency must use exact version 2.9.4" "$non_exact_fixture" \
  --output "$non_exact_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false

duplicate_pin_fixture="$(setup_fixture duplicate-sparkle-pin)"
write_update_config "$duplicate_pin_fixture" "2.9.4" ""
install_mock_swift "$duplicate_pin_fixture"
/usr/bin/plutil -insert pins.1 -json \
  '{"identity":"sparkle","kind":"remoteSourceControl","location":"https://example.com/Sparkle","state":{"revision":"decoy","version":"2.9.4"}}' \
  "$duplicate_pin_fixture/Package.resolved"
assert_rejected "Package.resolved must contain exactly one Sparkle pin" "$duplicate_pin_fixture" \
  --output "$duplicate_pin_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false

wrong_revision_fixture="$(setup_fixture wrong-sparkle-revision)"
write_update_config "$wrong_revision_fixture" "2.9.4" ""
install_mock_swift "$wrong_revision_fixture"
/usr/bin/plutil -replace pins.0.state.revision -string "0000000000000000000000000000000000000000" \
  "$wrong_revision_fixture/Package.resolved"
assert_rejected "Package.resolved Sparkle pin does not match the approved lock" "$wrong_revision_fixture" \
  --output "$wrong_revision_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false

single_arch_updates_fixture="$(setup_fixture single-arch-updates)"
write_update_config "$single_arch_updates_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
assert_rejected "updates-enabled requires exactly arm64 and x86_64" "$single_arch_updates_fixture" \
  --output "$single_arch_updates_fixture/dist" --configuration release \
  --architectures arm64 --updates-enabled true

resource_fixture="$(setup_fixture resource-mismatch)"
write_update_config "$resource_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$resource_fixture"
export PACKAGE_TEST_RESOURCE_MISMATCH=true
assert_rejected "resource sets differ between architectures" "$resource_fixture" \
  --output "$resource_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
[[ ! -e "$resource_fixture/dist" ]] || fail "failed package fixture polluted the output path"
unset PACKAGE_TEST_RESOURCE_MISMATCH

special_name_fixture="$(setup_fixture special-resource-names)"
write_update_config "$special_name_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$special_name_fixture"
export PACKAGE_TEST_SPECIAL_RESOURCE_NAMES=true
assert_rejected "resource sets differ between architectures" "$special_name_fixture" \
  --output "$special_name_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
unset PACKAGE_TEST_SPECIAL_RESOURCE_NAMES

wrong_input_fixture="$(setup_fixture wrong-input-slice)"
write_update_config "$wrong_input_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$wrong_input_fixture"
export PACKAGE_TEST_WRONG_INPUT_SLICE=true
assert_rejected "input executable architecture mismatch for arm64" "$wrong_input_fixture" \
  --output "$wrong_input_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
unset PACKAGE_TEST_WRONG_INPUT_SLICE

wrong_merged_fixture="$(setup_fixture wrong-merged-result)"
write_update_config "$wrong_merged_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$wrong_merged_fixture"
export PACKAGE_TEST_WRONG_MERGED_RESULT=true
assert_rejected "merged executable architecture mismatch" "$wrong_merged_fixture" \
  --output "$wrong_merged_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
unset PACKAGE_TEST_WRONG_MERGED_RESULT

missing_rpath_fixture="$(setup_fixture missing-rpath-slice)"
write_update_config "$missing_rpath_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$missing_rpath_fixture"
export PACKAGE_TEST_MISSING_RPATH_ARCH=x86_64
assert_rejected "missing LC_RPATH @executable_path/../Frameworks for x86_64" "$missing_rpath_fixture" \
  --output "$missing_rpath_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
unset PACKAGE_TEST_MISSING_RPATH_ARCH

escaped_link_fixture="$(setup_fixture escaped-newline-symlink)"
write_update_config "$escaped_link_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$escaped_link_fixture"
export PACKAGE_TEST_ESCAPED_NEWLINE_SYMLINK=true
assert_rejected "escaped Sparkle.framework symlink" "$escaped_link_fixture" \
  --output "$escaped_link_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
unset PACKAGE_TEST_ESCAPED_NEWLINE_SYMLINK

symlink_output_fixture="$(setup_fixture symlink-output)"
write_update_config "$symlink_output_fixture" "2.9.4" ""
install_mock_swift "$symlink_output_fixture"
mkdir -p "$symlink_output_fixture/dist" "$symlink_output_fixture/elsewhere.app"
ln -s "$symlink_output_fixture/elsewhere.app" "$symlink_output_fixture/dist/CodexRadar.app"
assert_rejected "destination application must not be a symlink" "$symlink_output_fixture" \
  --output "$symlink_output_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false
[[ -L "$symlink_output_fixture/dist/CodexRadar.app" ]] || fail "symlink destination was replaced"

parent_race_fixture="$(setup_fixture parent-identity-race)"
write_update_config "$parent_race_fixture" "2.9.4" ""
install_mock_swift "$parent_race_fixture"
mkdir -p "$parent_race_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$parent_race_fixture/dist/CodexRadar.app/marker"
start_paused_package "$parent_race_fixture" before-rename
mv "$parent_race_fixture/dist" "$parent_race_fixture/original-dist"
mkdir "$parent_race_fixture/dist"
printf 'replacement parent\n' >"$parent_race_fixture/dist/marker"
finish_paused_rejection "output parent identity changed before commit"
[[ "$(cat "$parent_race_fixture/dist/marker")" == "replacement parent" ]] ||
  fail "parent race fixture modified the replacement parent"
[[ "$(cat "$parent_race_fixture/original-dist/CodexRadar.app/marker")" == "old artifact" ]] ||
  fail "parent race fixture replaced the original destination"

staging_race_fixture="$(setup_fixture staging-identity-race)"
write_update_config "$staging_race_fixture" "2.9.4" ""
install_mock_swift "$staging_race_fixture"
mkdir -p "$staging_race_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$staging_race_fixture/dist/CodexRadar.app/marker"
start_paused_package "$staging_race_fixture" before-rename
staging_path="$(find "$staging_race_fixture/dist" -maxdepth 1 -type d -name '.CodexRadar.app.package.*' -print -quit)"
[[ -n "$staging_path" ]] || fail "staging race fixture did not create staging"
mv "$staging_path" "$staging_path.original"
mkdir "$staging_path"
printf 'replacement staging\n' >"$staging_path/marker"
finish_paused_rejection "staged application identity changed before commit"
[[ "$(cat "$staging_path/marker")" == "replacement staging" ]] ||
  fail "staging race fixture deleted the replacement staging tree"
[[ -d "$staging_path.original/Contents" ]] ||
  fail "staging race fixture deleted the original staging tree"
[[ "$(cat "$staging_race_fixture/dist/CodexRadar.app/marker")" == "old artifact" ]] ||
  fail "staging race fixture replaced the destination"

destination_race_fixture="$(setup_fixture destination-identity-race)"
write_update_config "$destination_race_fixture" "2.9.4" ""
install_mock_swift "$destination_race_fixture"
mkdir -p "$destination_race_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$destination_race_fixture/dist/CodexRadar.app/marker"
start_paused_package "$destination_race_fixture" before-rename
mv "$destination_race_fixture/dist/CodexRadar.app" \
  "$destination_race_fixture/dist/CodexRadar.original.app"
mkdir "$destination_race_fixture/dist/CodexRadar.app"
printf 'replacement destination\n' >"$destination_race_fixture/dist/CodexRadar.app/marker"
finish_paused_rejection "destination application identity changed before commit"
[[ "$(cat "$destination_race_fixture/dist/CodexRadar.app/marker")" == "replacement destination" ]] ||
  fail "destination race fixture modified the replacement destination"
[[ "$(cat "$destination_race_fixture/dist/CodexRadar.original.app/marker")" == "old artifact" ]] ||
  fail "destination race fixture deleted the original destination"

signal_fixture="$(setup_fixture signal-before-commit)"
write_update_config "$signal_fixture" "2.9.4" ""
install_mock_swift "$signal_fixture"
mkdir -p "$signal_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$signal_fixture/dist/CodexRadar.app/marker"
start_paused_package "$signal_fixture" before-commit
kill -TERM "$background_pid"
if wait "$background_pid"; then
  fail "signal before commit fixture unexpectedly succeeded"
fi
signal_output="$(cat "$background_log")"
[[ "$signal_output" == *"packaging interrupted before commit"* ]] || {
  echo "$signal_output" >&2
  fail "signal before commit fixture did not report interruption"
}
[[ "$(cat "$signal_fixture/dist/CodexRadar.app/marker")" == "old artifact" ]] ||
  fail "signal before commit replaced the existing application"

active_lock_fixture="$(setup_fixture active-lock)"
write_update_config "$active_lock_fixture" "2.9.4" ""
install_mock_swift "$active_lock_fixture"
start_paused_package "$active_lock_fixture" after-lock
lock_path="$active_lock_fixture/dist/.CodexRadar.package.lock"
[[ -f "$lock_path" && ! -L "$lock_path" ]] || fail "active lock is not a real file"
grep -Eq '^pid=[0-9]+$' "$lock_path" || fail "lock owner record is missing pid"
grep -Eq '^start=[0-9]+\.[0-9]+$' "$lock_path" || fail "lock owner record is missing process start"
assert_rejected "output path is locked by another packager" "$active_lock_fixture" \
  --output "$active_lock_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false
: >"$background_continue"
wait "$background_pid" || {
  cat "$background_log" >&2
  fail "active lock owner failed after release"
}

stale_lock_fixture="$(setup_fixture stale-lock)"
write_update_config "$stale_lock_fixture" "2.9.4" ""
install_mock_swift "$stale_lock_fixture"
start_paused_package "$stale_lock_fixture" after-lock
stale_lock_path="$stale_lock_fixture/dist/.CodexRadar.package.lock"
[[ -f "$stale_lock_path" && ! -L "$stale_lock_path" ]] ||
  fail "stale lock fixture did not create an advisory lock file"
kill -KILL "$background_pid"
if wait "$background_pid" 2>/dev/null; then
  fail "stale lock owner unexpectedly survived SIGKILL"
fi
[[ -f "$stale_lock_path" && ! -L "$stale_lock_path" ]] ||
  fail "SIGKILL removed the advisory lock file"
assert_succeeds "$stale_lock_fixture" \
  --output "$stale_lock_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false
[[ -f "$stale_lock_path" && ! -L "$stale_lock_path" ]] ||
  fail "successful advisory lock recovery changed the stable lock file"

cleanup_fixture="$(setup_fixture cleanup-failure)"
write_update_config "$cleanup_fixture" "2.9.4" ""
install_mock_swift "$cleanup_fixture"
mkdir -p "$cleanup_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$cleanup_fixture/dist/CodexRadar.app/marker"
/bin/chmod 500 "$cleanup_fixture/dist/CodexRadar.app"
(
  umask 077
  assert_succeeds "$cleanup_fixture" \
    --output "$cleanup_fixture/dist" --configuration debug \
    --architectures arm64 --updates-enabled false
)
[[ -f "$cleanup_fixture/dist/CodexRadar.app/Contents/MacOS/CodexRadar" ]] ||
  fail "cleanup failure did not leave the committed application"
[[ "$(stat -f '%Lp' "$cleanup_fixture/dist/CodexRadar.app")" == 755 ]] ||
  fail "committed application root mode is not 0755"
old_staging_count="$(find "$cleanup_fixture/dist" -maxdepth 1 -name '.CodexRadar.app.package.*' | wc -l | tr -d ' ')"
[[ "$old_staging_count" == 1 ]] || fail "cleanup failure fixture did not preserve old staging for later cleanup"
old_staging_path="$(find "$cleanup_fixture/dist" -maxdepth 1 -name '.CodexRadar.app.package.*' -print -quit)"
/bin/chmod 700 "$old_staging_path"

compile_fixture_executables() {
  printf '%s\n' 'int main(void) { return 0; }' >"$fixture_dir/task6-main.c"
  /usr/bin/xcrun --sdk macosx clang -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 "$fixture_dir/task6-main.c" \
    -o "$fixture_dir/task6-universal"
  /usr/bin/lipo -thin arm64 "$fixture_dir/task6-universal" \
    -output "$fixture_dir/task6-arm64"
}

write_bundle_plist() {
  local plist_path="$1" bundle_id="$2" executable_name="$3" package_type="$4"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/bin/plutil -insert CFBundleExecutable -string "$executable_name" "$plist_path"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_id" "$plist_path"
  /usr/bin/plutil -insert CFBundlePackageType -string "$package_type" "$plist_path"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 2.9.4 "$plist_path"
  /usr/bin/plutil -insert CFBundleVersion -string 2059 "$plist_path"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string 10.13 "$plist_path"
}

write_release_plist() {
  local plist_path="$1"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/bin/plutil -insert CFBundleExecutable -string CodexRadar "$plist_path"
  /usr/bin/plutil -insert CFBundleIdentifier -string com.terence.codex-radar "$plist_path"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$plist_path"
  /usr/bin/plutil -insert CFBundleShortVersionString -string \
    "$CURRENT_MARKETING_VERSION" "$plist_path"
  /usr/bin/plutil -insert CFBundleVersion -string "$CURRENT_BUILD_NUMBER" "$plist_path"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$plist_path"
  /usr/bin/plutil -insert SUFeedURL -string \
    https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml "$plist_path"
  /usr/bin/plutil -insert SUPublicEDKey -string \
    sRHMX+P9of0173XYLQz0F4b8aZ9g5hiNVsJXe7pp6o4= "$plist_path"
  /usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "$plist_path"
  /usr/bin/plutil -insert SUAutomaticallyUpdate -bool true "$plist_path"
  /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$plist_path"
  /usr/bin/plutil -insert SURequireSignedFeed -bool true "$plist_path"
  /usr/bin/plutil -insert CodexRadarUpdatesEnabled -bool true "$plist_path"
}

setup_task6_app() {
  local name="$1"
  local task_root="$fixture_dir/task6-$name"
  local app="$task_root/CodexRadar.app"
  local framework="$app/Contents/Frameworks/Sparkle.framework"
  local version_root="$framework/Versions/B"
  local xpc_name executable_name bundle_id xpc_path

  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/en.lproj" \
    "$app/Contents/Resources/zh-hans.lproj" "$version_root/Resources" \
    "$version_root/Headers" "$version_root/Modules" "$version_root/PrivateHeaders" \
    "$version_root/Updater.app/Contents/MacOS" "$version_root/XPCServices"
  printf 'preserve fixture root\n' >"$task_root/root-marker"
  printf 'English\n' >"$app/Contents/Resources/en.lproj/Localizable.strings"
  printf 'Chinese\n' >"$app/Contents/Resources/zh-hans.lproj/Localizable.strings"
  printf 'newline-safe resource\n' >"$app/Contents/Resources/newline
resource.txt"
  printf 'tab-safe resource\n' >"$app/Contents/Resources/tab	resource.txt"
  cp "$fixture_dir/task6-universal" "$app/Contents/MacOS/CodexRadar"
  cp "$fixture_dir/task6-universal" "$version_root/Autoupdate"
  cp "$fixture_dir/task6-universal" "$version_root/Sparkle"
  cp "$fixture_dir/task6-universal" \
    "$version_root/Updater.app/Contents/MacOS/Updater"
  write_bundle_plist "$version_root/Updater.app/Contents/Info.plist" \
    org.sparkle-project.Sparkle.Updater Updater APPL
  write_bundle_plist "$version_root/Resources/Info.plist" \
    org.sparkle-project.Sparkle Sparkle FMWK

  for xpc_name in Downloader Installer; do
    case "$xpc_name" in
      Downloader) bundle_id=org.sparkle-project.DownloaderService ;;
      Installer) bundle_id=org.sparkle-project.InstallerLauncher ;;
    esac
    executable_name="$xpc_name"
    xpc_path="$version_root/XPCServices/$xpc_name.xpc"
    mkdir -p "$xpc_path/Contents/MacOS"
    cp "$fixture_dir/task6-universal" "$xpc_path/Contents/MacOS/$executable_name"
    write_bundle_plist "$xpc_path/Contents/Info.plist" \
      "$bundle_id" "$executable_name" 'XPC!'
  done

  ln -s B "$framework/Versions/Current"
  ln -s Versions/Current/Headers "$framework/Headers"
  ln -s Versions/Current/Modules "$framework/Modules"
  ln -s Versions/Current/PrivateHeaders "$framework/PrivateHeaders"
  ln -s Versions/Current/Resources "$framework/Resources"
  ln -s Versions/Current/Autoupdate "$framework/Autoupdate"
  ln -s Versions/Current/Updater.app "$framework/Updater.app"
  ln -s Versions/Current/XPCServices "$framework/XPCServices"
  ln -s Versions/Current/Sparkle "$framework/Sparkle"
  write_release_plist "$app/Contents/Info.plist"
  chmod 0755 "$app" "$app/Contents/MacOS/CodexRadar" \
    "$version_root/Autoupdate" "$version_root/Sparkle" \
    "$version_root/Updater.app/Contents/MacOS/Updater" \
    "$version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  /bin/realpath "$task_root"
}

assert_fixture_root_preserved() {
  local task_root="$1"

  [[ -f "$task_root/root-marker" ]] || fail "Task 6 fixture root was deleted"
  [[ "$(cat "$task_root/root-marker")" == "preserve fixture root" ]] ||
    fail "Task 6 fixture root marker was modified"
}

assert_task6_rejected() {
  local expected_message="$1" task_root="$2"
  shift 2

  if output="$("$@" 2>&1)"; then
    fail "Task 6 fixture unexpectedly succeeded: $expected_message"
  fi
  [[ "$output" == *"$expected_message"* ]] || {
    echo "$output" >&2
    fail "Task 6 fixture did not report: $expected_message"
  }
  assert_fixture_root_preserved "$task_root"
}

sign_task6_app() {
  local task_root="$1"

  "$SIGN_SCRIPT" --app "$task_root/CodexRadar.app" --signing-mode adhoc
}

snapshot_task6_app() {
  local app_path="$1" output_path="$2" entry_path relative_path mode digest

  : >"$output_path"
  while IFS= read -r -d '' entry_path; do
    relative_path="${entry_path#"$app_path"/}"
    mode="$(/usr/bin/stat -f '%Lp' "$entry_path")"
    if [[ -L "$entry_path" ]]; then
      printf 'path\0%s\0type\0link\0mode\0%s\0target\0%s\0' \
        "$relative_path" "$mode" "$(/usr/bin/readlink "$entry_path")" >>"$output_path"
    elif [[ -d "$entry_path" ]]; then
      printf 'path\0%s\0type\0directory\0mode\0%s\0' \
        "$relative_path" "$mode" >>"$output_path"
    elif [[ -f "$entry_path" ]]; then
      digest="$(/usr/bin/shasum -a 256 "$entry_path" | /usr/bin/awk '{print $1}')"
      printf 'path\0%s\0type\0file\0mode\0%s\0sha256\0%s\0' \
        "$relative_path" "$mode" "$digest" >>"$output_path"
    else
      fail "unsupported Task 6 snapshot entry"
    fi
  done < <(/usr/bin/find -s "$app_path" -mindepth 1 -print0)
}

verify_task6_app() {
  local task_root="$1"

  "$VERIFY_SCRIPT" --app "$task_root/CodexRadar.app" \
    --architectures "arm64 x86_64" --updates-enabled true \
    --signing-mode adhoc
}

compile_fixture_executables

signing_order_fixture="$(setup_task6_app signing-order)"
mkdir "$signing_order_fixture/bin"
cat >"$signing_order_fixture/bin/codesign" <<'MOCK_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == --verify ]]; then
  exit 0
fi
[[ "$#" -eq 4 && "$1" == --force && "$2" == --sign && "$3" == - ]] || {
  echo "unexpected codesign arguments" >&2
  exit 1
}
printf '%s\0' "$4" >>"$SIGN_APP_TEST_LOG"
MOCK_CODESIGN
chmod +x "$signing_order_fixture/bin/codesign"
SIGN_APP_TEST_LOG="$signing_order_fixture/signing-order.log" \
SIGN_APP_CODESIGN_EXECUTABLE="$signing_order_fixture/bin/codesign" \
  "$SIGN_SCRIPT" --app "$signing_order_fixture/CodexRadar.app" --signing-mode adhoc
actual_signing_order=()
while IFS= read -r -d '' signed_path; do
  actual_signing_order+=("$signed_path")
done <"$signing_order_fixture/signing-order.log"
framework="$signing_order_fixture/CodexRadar.app/Contents/Frameworks/Sparkle.framework"
staged_app="${actual_signing_order[0]%%/Contents/*}"
framework="$staged_app/Contents/Frameworks/Sparkle.framework"
expected_signing_order=(
  "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$framework/Versions/B/XPCServices/Downloader.xpc"
  "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "$framework/Versions/B/XPCServices/Installer.xpc"
  "$framework/Versions/B/Autoupdate"
  "$framework/Versions/B/Updater.app"
  "$framework"
  "$staged_app/Contents/MacOS/CodexRadar"
  "$staged_app"
)
[[ "${#actual_signing_order[@]}" -eq "${#expected_signing_order[@]}" ]] ||
  fail "sign_app.sh used an unexpected signing target count"
for signing_index in "${!expected_signing_order[@]}"; do
  [[ "${actual_signing_order[$signing_index]}" == \
    "${expected_signing_order[$signing_index]}" ]] ||
    fail "sign_app.sh used the wrong inside-out signing order"
done
assert_fixture_root_preserved "$signing_order_fixture"

stage_mode_fixture="$(setup_task6_app signing-stage-mode)"
mkdir "$stage_mode_fixture/mode-bin"
cat >"$stage_mode_fixture/mode-bin/ditto" <<'MOCK_MODE_DITTO'
#!/usr/bin/env bash
set -euo pipefail

"$SIGN_APP_TEST_REAL_DITTO" "$@"
destination="${!#}"
case "$destination" in
  */Contents) staged_root="${destination%/Contents}" ;;
  *) staged_root="$destination" ;;
esac
printf 'copy:%s\n' "$(/usr/bin/stat -f '%Lp' "$staged_root")" \
  >>"$SIGN_APP_TEST_MODE_LOG"
MOCK_MODE_DITTO
cat >"$stage_mode_fixture/mode-bin/codesign" <<'MOCK_MODE_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

target="${!#}"
case "$target" in
  */Contents/*) staged_root="${target%%/Contents/*}" ;;
  *) staged_root="$target" ;;
esac
if [[ "$1" == --verify ]]; then
  phase=verify
else
  phase=sign
fi
printf '%s:%s\n' "$phase" "$(/usr/bin/stat -f '%Lp' "$staged_root")" \
  >>"$SIGN_APP_TEST_MODE_LOG"
MOCK_MODE_CODESIGN
chmod +x "$stage_mode_fixture/mode-bin/"*
SIGN_APP_TEST_REAL_DITTO=/usr/bin/ditto \
SIGN_APP_TEST_MODE_LOG="$stage_mode_fixture/stage-modes.log" \
SIGN_APP_DITTO_EXECUTABLE="$stage_mode_fixture/mode-bin/ditto" \
SIGN_APP_CODESIGN_EXECUTABLE="$stage_mode_fixture/mode-bin/codesign" \
  "$SIGN_SCRIPT" --app "$stage_mode_fixture/CodexRadar.app" --signing-mode adhoc
[[ "$(grep -c '^copy:700$' "$stage_mode_fixture/stage-modes.log")" -eq 1 ]] ||
  fail "private signing stage was not 0700 throughout copying"
[[ "$(grep -c '^sign:700$' "$stage_mode_fixture/stage-modes.log")" -eq 9 ]] ||
  fail "private signing stage was not 0700 throughout signing"
[[ "$(grep -c '^verify:755$' "$stage_mode_fixture/stage-modes.log")" -eq 1 ]] ||
  fail "private signing stage was not 0755 for final verification"
[[ "$(/usr/bin/stat -f '%Lp' "$stage_mode_fixture/CodexRadar.app")" == 755 ]] ||
  fail "committed application root does not satisfy the 0755 contract"

signing_lifecycle_fixture="$(setup_task6_app signing-stage-lifecycle)"
mkdir "$signing_lifecycle_fixture/lifecycle-bin" "$signing_lifecycle_fixture/control"
cat >"$signing_lifecycle_fixture/lifecycle-bin/ditto" <<'MOCK_LIFECYCLE_DITTO'
#!/usr/bin/env bash
set -euo pipefail

"$SIGN_APP_TEST_REAL_DITTO" "$@"
destination="${!#}"
case "$destination" in
  */.CodexRadar.app.sign.*|*/.CodexRadar.app.sign.*/Contents)
    printf '%s\n' "$destination" >>"$SIGN_APP_TEST_COPY_LOG"
    ;;
esac
MOCK_LIFECYCLE_DITTO
cat >"$signing_lifecycle_fixture/lifecycle-bin/codesign" <<'MOCK_LIFECYCLE_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

exit 0
MOCK_LIFECYCLE_CODESIGN
chmod +x "$signing_lifecycle_fixture/lifecycle-bin/"*
lifecycle_environment=(
  SIGN_APP_DITTO_EXECUTABLE="$signing_lifecycle_fixture/lifecycle-bin/ditto"
  SIGN_APP_CODESIGN_EXECUTABLE="$signing_lifecycle_fixture/lifecycle-bin/codesign"
  SIGN_APP_TEST_REAL_DITTO=/usr/bin/ditto
  SIGN_APP_TEST_COPY_LOG="$signing_lifecycle_fixture/copy.log"
)
env "${lifecycle_environment[@]}" SIGN_APP_TEST_PAUSE_PHASE=after-copy \
  SIGN_APP_TEST_CONTROL_DIR="$signing_lifecycle_fixture/control" \
  "$SIGN_SCRIPT" --app "$signing_lifecycle_fixture/CodexRadar.app" \
  --signing-mode adhoc >"$signing_lifecycle_fixture/first-signer.log" 2>&1 &
first_signer_pid=$!
signer_ready=false
for _ in $(seq 1 300); do
  if [[ -f "$signing_lifecycle_fixture/control/ready" ]]; then
    signer_ready=true
    break
  fi
  /bin/sleep 0.01
done
if [[ "$signer_ready" != true ]]; then
  /bin/kill -TERM "$first_signer_pid" >/dev/null 2>&1 || true
  wait "$first_signer_pid" >/dev/null 2>&1 || true
  cat "$signing_lifecycle_fixture/first-signer.log" >&2
  fail "signer did not pause after private staging copy"
fi
staged_during_copy=("$signing_lifecycle_fixture"/.CodexRadar.app.sign.*)
[[ "${#staged_during_copy[@]}" -eq 1 && -d "${staged_during_copy[0]}" && \
  ! -L "${staged_during_copy[0]}" ]] ||
  fail "signer did not retain exactly one private stage while paused"
[[ "$(/usr/bin/stat -f '%Lp' "${staged_during_copy[0]}")" == 700 ]] ||
  fail "paused private signing stage was not 0700"
assert_task6_rejected "output path is locked by another packager" \
  "$signing_lifecycle_fixture" env "${lifecycle_environment[@]}" \
  "$SIGN_SCRIPT" --app "$signing_lifecycle_fixture/CodexRadar.app" \
  --signing-mode adhoc
[[ "$(wc -l <"$signing_lifecycle_fixture/copy.log" | tr -d ' ')" -eq 1 ]] ||
  fail "concurrent signer copied an application before acquiring the signing lock"
mv "$signing_lifecycle_fixture/CodexRadar.app" \
  "$signing_lifecycle_fixture/source-before-replacement.app"
/usr/bin/ditto "$signing_lifecycle_fixture/source-before-replacement.app" \
  "$signing_lifecycle_fixture/CodexRadar.app"
replacement_inode="$(/usr/bin/stat -f '%i' \
  "$signing_lifecycle_fixture/CodexRadar.app")"
snapshot_task6_app "$signing_lifecycle_fixture/CodexRadar.app" \
  "$signing_lifecycle_fixture/replacement-before.snapshot"
: >"$signing_lifecycle_fixture/control/continue"
if wait "$first_signer_pid"; then
  fail "signer committed after source application identity replacement"
fi
grep -F "source application identity changed during staging" \
  "$signing_lifecycle_fixture/first-signer.log" >/dev/null || {
  cat "$signing_lifecycle_fixture/first-signer.log" >&2
  fail "signer did not report source application identity replacement"
}
[[ "$(/usr/bin/stat -f '%i' "$signing_lifecycle_fixture/CodexRadar.app")" == \
  "$replacement_inode" ]] ||
  fail "failed signer replaced the new source application"
snapshot_task6_app "$signing_lifecycle_fixture/CodexRadar.app" \
  "$signing_lifecycle_fixture/replacement-after.snapshot"
/usr/bin/cmp -s "$signing_lifecycle_fixture/replacement-before.snapshot" \
  "$signing_lifecycle_fixture/replacement-after.snapshot" ||
  fail "failed signer changed the replacement application tree"
[[ -z "$(/usr/bin/find "$signing_lifecycle_fixture" -maxdepth 1 \
  -name '.CodexRadar.app.sign.*' -print -quit)" ]] ||
  fail "failed signer retained a private signing stage"
env "${lifecycle_environment[@]}" \
  "$SIGN_SCRIPT" --app "$signing_lifecycle_fixture/CodexRadar.app" \
  --signing-mode adhoc || fail "signing lock was not released after staging failure"

swap_identity_fixture="$(setup_task6_app signing-swap-expected-identity)"
mkdir "$swap_identity_fixture/swap-bin" "$swap_identity_fixture/control"
cat >"$swap_identity_fixture/swap-bin/codesign" <<'MOCK_SWAP_IDENTITY_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == --verify && -n "${SIGN_APP_TEST_VERIFY_READY:-}" ]]; then
  : >"$SIGN_APP_TEST_VERIFY_READY"
  while [[ ! -e "$SIGN_APP_TEST_VERIFY_CONTINUE" ]]; do
    /bin/sleep 0.01
  done
fi
exit 0
MOCK_SWAP_IDENTITY_CODESIGN
chmod +x "$swap_identity_fixture/swap-bin/codesign"
SIGN_APP_CODESIGN_EXECUTABLE="$swap_identity_fixture/swap-bin/codesign" \
SIGN_APP_TEST_VERIFY_READY="$swap_identity_fixture/control/ready" \
SIGN_APP_TEST_VERIFY_CONTINUE="$swap_identity_fixture/control/continue" \
  "$SIGN_SCRIPT" --app "$swap_identity_fixture/CodexRadar.app" \
  --signing-mode adhoc >"$swap_identity_fixture/signer.log" 2>&1 &
swap_identity_signer_pid=$!
swap_identity_ready=false
for _ in $(seq 1 500); do
  if [[ -f "$swap_identity_fixture/control/ready" ]]; then
    swap_identity_ready=true
    break
  fi
  /bin/sleep 0.01
done
if [[ "$swap_identity_ready" != true ]]; then
  /bin/kill -TERM "$swap_identity_signer_pid" >/dev/null 2>&1 || true
  wait "$swap_identity_signer_pid" >/dev/null 2>&1 || true
  cat "$swap_identity_fixture/signer.log" >&2
  fail "signer did not pause during final staged verification"
fi
mv "$swap_identity_fixture/CodexRadar.app" \
  "$swap_identity_fixture/source-before-final-replacement.app"
/usr/bin/ditto "$swap_identity_fixture/source-before-final-replacement.app" \
  "$swap_identity_fixture/CodexRadar.app"
final_replacement_inode="$(/usr/bin/stat -f '%i' \
  "$swap_identity_fixture/CodexRadar.app")"
snapshot_task6_app "$swap_identity_fixture/CodexRadar.app" \
  "$swap_identity_fixture/final-replacement-before.snapshot"
: >"$swap_identity_fixture/control/continue"
if wait "$swap_identity_signer_pid"; then
  fail "signer replaced an application installed during final verification"
fi
grep -F "destination application identity does not match expected source" \
  "$swap_identity_fixture/signer.log" >/dev/null || {
  cat "$swap_identity_fixture/signer.log" >&2
  fail "atomic signer did not report destination identity replacement"
}
[[ "$(/usr/bin/stat -f '%i' "$swap_identity_fixture/CodexRadar.app")" == \
  "$final_replacement_inode" ]] ||
  fail "atomic signer replaced the newer application"
snapshot_task6_app "$swap_identity_fixture/CodexRadar.app" \
  "$swap_identity_fixture/final-replacement-after.snapshot"
/usr/bin/cmp -s "$swap_identity_fixture/final-replacement-before.snapshot" \
  "$swap_identity_fixture/final-replacement-after.snapshot" ||
  fail "atomic signer changed the newer application tree"
[[ -z "$(/usr/bin/find "$swap_identity_fixture" -maxdepth 1 \
  -name '.CodexRadar.app.sign.*' -print -quit)" ]] ||
  fail "destination identity failure retained a signed private stage"
SIGN_APP_CODESIGN_EXECUTABLE="$swap_identity_fixture/swap-bin/codesign" \
  "$SIGN_SCRIPT" --app "$swap_identity_fixture/CodexRadar.app" \
  --signing-mode adhoc || fail "signing lock was not released after swap rejection"

developer_id_fixture="$(setup_task6_app developer-id-inputs)"
assert_task6_rejected "developer-id signing requires DEVELOPER_ID_APPLICATION" \
  "$developer_id_fixture" env -u DEVELOPER_ID_APPLICATION \
  -u APP_STORE_CONNECT_API_KEY_PATH -u APP_STORE_CONNECT_KEY_ID \
  -u APP_STORE_CONNECT_ISSUER_ID "$SIGN_SCRIPT" \
  --app "$developer_id_fixture/CodexRadar.app" --signing-mode developer-id

setup_developer_id_mocks() {
  local task_root="$1"

  mkdir -p "$task_root/developer-bin"
  : >"$task_root/codesign-calls"
  printf 'mock private key\n' >"$task_root/AuthKey_TEST.p8"
  cat >"$task_root/developer-bin/security" <<'MOCK_SECURITY'
#!/usr/bin/env bash
set -euo pipefail

[[ "$*" == "find-identity -v -p codesigning" ]]
printf '%s\n' "$SIGN_APP_TEST_IDENTITIES"
MOCK_SECURITY
  cat >"$task_root/developer-bin/xcrun" <<'MOCK_XCRUN'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\0' "$@" >>"$SIGN_APP_TEST_NOTARY_LOG"
[[ "${SIGN_APP_TEST_NOTARY_VALID:-true}" == true ]]
MOCK_XCRUN
  cat >"$task_root/developer-bin/codesign" <<'MOCK_DEVELOPER_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\0' "$@" >>"$SIGN_APP_TEST_CODESIGN_LOG"
exit 99
MOCK_DEVELOPER_CODESIGN
  chmod +x "$task_root/developer-bin/"*
}

developer_identity_fixture="$(setup_task6_app developer-identity-preflight)"
setup_developer_id_mocks "$developer_identity_fixture"
developer_identity_name='Developer ID Application: Test Example (TEAMID1234)'
developer_identity_environment=(
  DEVELOPER_ID_APPLICATION="$developer_identity_name"
  APP_STORE_CONNECT_API_KEY_PATH="$developer_identity_fixture/AuthKey_TEST.p8"
  APP_STORE_CONNECT_KEY_ID=TESTKEY123
  APP_STORE_CONNECT_ISSUER_ID=00000000-0000-0000-0000-000000000000
  SIGN_APP_SECURITY_EXECUTABLE="$developer_identity_fixture/developer-bin/security"
  SIGN_APP_XCRUN_EXECUTABLE="$developer_identity_fixture/developer-bin/xcrun"
  SIGN_APP_CODESIGN_EXECUTABLE="$developer_identity_fixture/developer-bin/codesign"
  SIGN_APP_TEST_NOTARY_LOG="$developer_identity_fixture/notary-calls"
  SIGN_APP_TEST_CODESIGN_LOG="$developer_identity_fixture/codesign-calls"
)
assert_task6_rejected "developer-id signing identity not found" \
  "$developer_identity_fixture" env "${developer_identity_environment[@]}" \
  SIGN_APP_TEST_IDENTITIES='     0 valid identities found' \
  "$SIGN_SCRIPT" --app "$developer_identity_fixture/CodexRadar.app" \
  --signing-mode developer-id
[[ ! -s "$developer_identity_fixture/codesign-calls" ]] ||
  fail "missing Developer ID identity reached codesign or ad-hoc fallback"

: >"$developer_identity_fixture/codesign-calls"
duplicate_identities="     1) 1111111111111111111111111111111111111111 \"$developer_identity_name\"
     2) 2222222222222222222222222222222222222222 \"$developer_identity_name\"
     2 valid identities found"
assert_task6_rejected "developer-id signing identity is ambiguous" \
  "$developer_identity_fixture" env "${developer_identity_environment[@]}" \
  SIGN_APP_TEST_IDENTITIES="$duplicate_identities" \
  "$SIGN_SCRIPT" --app "$developer_identity_fixture/CodexRadar.app" \
  --signing-mode developer-id
[[ ! -s "$developer_identity_fixture/codesign-calls" ]] ||
  fail "ambiguous Developer ID identity reached codesign or ad-hoc fallback"

: >"$developer_identity_fixture/codesign-calls"
development_identity_hash=3333333333333333333333333333333333333333
development_identity_name='Apple Development: Test Example (TEAMID1234)'
development_identity="     1) $development_identity_hash \"$development_identity_name\"
     1 valid identities found"
assert_task6_rejected "resolved signing identity is not a Developer ID Application certificate" \
  "$developer_identity_fixture" env "${developer_identity_environment[@]}" \
  DEVELOPER_ID_APPLICATION="$development_identity_hash" \
  SIGN_APP_TEST_IDENTITIES="$development_identity" \
  "$SIGN_SCRIPT" --app "$developer_identity_fixture/CodexRadar.app" \
  --signing-mode developer-id
[[ ! -s "$developer_identity_fixture/codesign-calls" ]] ||
  fail "non-Developer ID identity reached codesign or ad-hoc fallback"

: >"$developer_identity_fixture/codesign-calls"
single_identity="     1) 1111111111111111111111111111111111111111 \"$developer_identity_name\"
     1 valid identities found"
assert_task6_rejected "developer-id notarization credential preflight failed" \
  "$developer_identity_fixture" env "${developer_identity_environment[@]}" \
  SIGN_APP_TEST_IDENTITIES="$single_identity" SIGN_APP_TEST_NOTARY_VALID=false \
  "$SIGN_SCRIPT" --app "$developer_identity_fixture/CodexRadar.app" \
  --signing-mode developer-id
[[ ! -s "$developer_identity_fixture/codesign-calls" ]] ||
  fail "invalid notarization credentials reached codesign or ad-hoc fallback"

signing_failure_fixture="$(setup_task6_app signing-failure-atomicity)"
mkdir "$signing_failure_fixture/failure-bin"
cat >"$signing_failure_fixture/failure-bin/codesign" <<'MOCK_FAILING_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == --verify ]]; then
  exit 0
fi
count=0
[[ ! -f "$SIGN_APP_TEST_COUNT" ]] || count="$(cat "$SIGN_APP_TEST_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$SIGN_APP_TEST_COUNT"
[[ "$count" -ne "$SIGN_APP_TEST_FAIL_AT" ]] || {
  echo "injected codesign failure" >&2
  exit 98
}
MOCK_FAILING_CODESIGN
chmod +x "$signing_failure_fixture/failure-bin/codesign"
snapshot_task6_app "$signing_failure_fixture/CodexRadar.app" \
  "$signing_failure_fixture/before-signing.snapshot"
assert_task6_rejected "injected codesign failure" "$signing_failure_fixture" \
  env SIGN_APP_CODESIGN_EXECUTABLE="$signing_failure_fixture/failure-bin/codesign" \
  SIGN_APP_TEST_COUNT="$signing_failure_fixture/codesign-count" \
  SIGN_APP_TEST_FAIL_AT=4 "$SIGN_SCRIPT" \
  --app "$signing_failure_fixture/CodexRadar.app" --signing-mode adhoc
snapshot_task6_app "$signing_failure_fixture/CodexRadar.app" \
  "$signing_failure_fixture/after-signing.snapshot"
/usr/bin/cmp -s "$signing_failure_fixture/before-signing.snapshot" \
  "$signing_failure_fixture/after-signing.snapshot" ||
  fail "codesign failure changed the original application tree"
[[ -z "$(/usr/bin/find "$signing_failure_fixture" -maxdepth 1 \
  -name '.CodexRadar.app.sign.*' -print -quit)" ]] ||
  fail "codesign failure retained a private signing stage"

valid_verify_fixture="$(setup_task6_app valid-verifier)"
sign_task6_app "$valid_verify_fixture"
verify_task6_app "$valid_verify_fixture"
assert_fixture_root_preserved "$valid_verify_fixture"

nested_signature_fixture="$(setup_task6_app nested-signature-verification)"
mkdir "$nested_signature_fixture/verify-bin"
cat >"$nested_signature_fixture/verify-bin/codesign" <<'MOCK_VERIFY_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == --verify ]]; then
  exit 0
fi
[[ "$1" == -d ]]
target="${!#}"
if [[ "$target" == */Installer.xpc/Contents/MacOS/Installer ]]; then
  echo 'Signature=not-adhoc' >&2
else
  echo 'Signature=adhoc' >&2
fi
MOCK_VERIFY_CODESIGN
chmod +x "$nested_signature_fixture/verify-bin/codesign"
assert_task6_rejected "code object is not signed with an ad-hoc identity" \
  "$nested_signature_fixture" env \
  VERIFY_APP_CODESIGN_EXECUTABLE="$nested_signature_fixture/verify-bin/codesign" \
  "$VERIFY_SCRIPT" --app "$nested_signature_fixture/CodexRadar.app" \
  --architectures "arm64 x86_64" --updates-enabled true --signing-mode adhoc

escaped_symlink_fixture="$(setup_task6_app escaped-app-symlink)"
printf 'outside application\n' >"$escaped_symlink_fixture/outside"
ln -s ../../../outside "$escaped_symlink_fixture/CodexRadar.app/Contents/Resources/escaped
link"
assert_task6_rejected "bundle symlink escapes application" "$escaped_symlink_fixture" \
  "$VERIFY_SCRIPT" --app "$escaped_symlink_fixture/CodexRadar.app" \
  --architectures "arm64 x86_64" --updates-enabled true --signing-mode adhoc

missing_xpc_fixture="$(setup_task6_app missing-xpc)"
mv "$missing_xpc_fixture/CodexRadar.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
  "$missing_xpc_fixture/removed-Installer.xpc"
assert_task6_rejected "missing Sparkle XPC service: Installer.xpc" "$missing_xpc_fixture" \
  "$VERIFY_SCRIPT" --app "$missing_xpc_fixture/CodexRadar.app" \
  --architectures "arm64 x86_64" --updates-enabled true --signing-mode adhoc

non_macho_fixture="$(setup_task6_app non-macho-executable)"
printf 'not Mach-O\n' >"$non_macho_fixture/CodexRadar.app/Contents/MacOS/CodexRadar"
chmod +x "$non_macho_fixture/CodexRadar.app/Contents/MacOS/CodexRadar"
assert_task6_rejected "expected executable is not Mach-O" "$non_macho_fixture" \
  "$VERIFY_SCRIPT" --app "$non_macho_fixture/CodexRadar.app" \
  --architectures "arm64 x86_64" --updates-enabled true --signing-mode adhoc

single_arch_fixture="$(setup_task6_app single-architecture-nested)"
cp "$fixture_dir/task6-arm64" \
  "$single_arch_fixture/CodexRadar.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
sign_task6_app "$single_arch_fixture"
assert_task6_rejected "Mach-O architecture mismatch" "$single_arch_fixture" \
  "$VERIFY_SCRIPT" --app "$single_arch_fixture/CodexRadar.app" \
  --architectures "arm64 x86_64" --updates-enabled true --signing-mode adhoc

mismatched_version_fixture="$(setup_task6_app mismatched-version)"
/usr/bin/plutil -replace CFBundleShortVersionString -string 9.9.9 \
  "$mismatched_version_fixture/CodexRadar.app/Contents/Info.plist"
sign_task6_app "$mismatched_version_fixture"
assert_task6_rejected "CFBundleShortVersionString does not match version.env" \
  "$mismatched_version_fixture" "$VERIFY_SCRIPT" \
  --app "$mismatched_version_fixture/CodexRadar.app" \
  --architectures "arm64 x86_64" --updates-enabled true --signing-mode adhoc

setup_release_fixture() {
  local name="$1"
  local release_root="$fixture_dir/task6-release-$name"

  mkdir -p "$release_root/script/lib" "$release_root/script/helpers" \
    "$release_root/config" "$release_root/bin"
  cp "$RELEASE_SCRIPT" "$SIGN_SCRIPT" "$VERIFY_SCRIPT" "$release_root/script/"
  cp "$ROOT_DIR/script/lib/release_common.sh" "$release_root/script/lib/"
  cp "$ROOT_DIR/script/helpers/atomic_swap.c" "$release_root/script/helpers/"
  cp "$ROOT_DIR/version.env" "$release_root/"
  cp "$ROOT_DIR/config/update.env" "$release_root/config/"
  cat >"$release_root/script/package_app.sh" <<'MOCK_PACKAGE_APP'
#!/usr/bin/env bash
set -euo pipefail

output_path=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    --configuration|--architectures|--updates-enabled)
      shift 2
      ;;
    *) exit 2 ;;
  esac
done
[[ -n "$output_path" ]]
mkdir -p "$output_path"
/usr/bin/ditto "$PACKAGE_RELEASE_TEST_APP_SOURCE" "$output_path/CodexRadar.app"
MOCK_PACKAGE_APP
  chmod +x "$release_root/script/"*.sh
  cat >"$release_root/bin/ditto" <<'MOCK_DITTO'
#!/usr/bin/env bash
set -euo pipefail

creating=false
for argument in "$@"; do
  [[ "$argument" != -c ]] || creating=true
done
if [[ "$creating" == false && "${PACKAGE_RELEASE_FAIL_EXTRACTION:-false}" == true ]]; then
  echo "injected extraction failure" >&2
  exit 97
fi
"$PACKAGE_RELEASE_REAL_DITTO" "$@"
if [[ "$creating" == true && -n "${PACKAGE_RELEASE_ARCHIVE_INJECTION:-}" ]]; then
  archive_path="${!#}"
  /usr/bin/python3 - "$archive_path" "$PACKAGE_RELEASE_ARCHIVE_INJECTION" <<'PYTHON'
import stat
import struct
import sys
import unicodedata
import zipfile

archive_path, injection = sys.argv[1:]
mode = "w" if injection == "root-not-directory" else "a"
with zipfile.ZipFile(archive_path, mode) as archive:
    if injection == "extra-top-level":
        archive.writestr("unexpected.txt", "unexpected\n")
    elif injection == "apple-double":
        archive.writestr("__MACOSX/._unexpected", "unexpected\n")
    elif injection == "path-traversal":
        archive.writestr("../escaped.txt", "unexpected\n")
    elif injection == "escaped-symlink":
        entry = zipfile.ZipInfo("CodexRadar.app/escaped-link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(entry, "../../escaped.txt")
    elif injection == "high-compression-symlink":
        entry = zipfile.ZipInfo("CodexRadar.app/high-ratio-link")
        entry.create_system = 3
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(entry, "a" * (1024 * 1024))
    elif injection == "oversized-symlink":
        entry = zipfile.ZipInfo("CodexRadar.app/oversized-link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(entry, "a" * 4097)
    elif injection == "oversized-regular":
        entry = zipfile.ZipInfo("CodexRadar.app/oversized.bin")
        entry.compress_type = zipfile.ZIP_DEFLATED
        with archive.open(entry, "w") as output:
            block = b"\0" * (1024 * 1024)
            for _ in range(65):
                output.write(block)
    elif injection == "oversized-total":
        block = b"x" * (1024 * 1024)
        for index in range(3):
            entry = zipfile.ZipInfo("CodexRadar.app/total-{}.bin".format(index))
            entry.compress_type = zipfile.ZIP_STORED
            with archive.open(entry, "w") as output:
                for _ in range(45):
                    output.write(block)
    elif injection == "oversized-compressed":
        block = b"x" * (1024 * 1024)
        for index in range(2):
            entry = zipfile.ZipInfo("CodexRadar.app/compressed-{}.bin".format(index))
            entry.compress_type = zipfile.ZIP_STORED
            with archive.open(entry, "w") as output:
                for _ in range(34):
                    output.write(block)
    elif injection == "many-entries":
        for index in range(2050):
            archive.writestr("CodexRadar.app/many/{:04d}".format(index), b"")
    elif injection == "case-collision":
        archive.writestr("CodexRadar.app/Contents/Resources/Collision", b"A")
        archive.writestr("CodexRadar.app/Contents/Resources/collision", b"a")
    elif injection == "unicode-collision":
        composed = unicodedata.normalize("NFC", "Cafe\u0301")
        decomposed = unicodedata.normalize("NFD", composed)
        archive.writestr("CodexRadar.app/Contents/Resources/" + composed, b"NFC")
        archive.writestr("CodexRadar.app/Contents/Resources/" + decomposed, b"NFD")
    elif injection == "ancestry-conflict":
        archive.writestr("CodexRadar.app/Contents/Resources/conflict", b"file")
        archive.writestr("CodexRadar.app/Contents/Resources/conflict/child", b"child")
    elif injection == "symlink-ancestor":
        entry = zipfile.ZipInfo("CodexRadar.app/resource-alias")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(entry, "Contents/Resources")
        archive.writestr("CodexRadar.app/resource-alias/overwrite", b"overwrite")
    elif injection == "symlink-cycle":
        for name, target in (("cycle-a", "cycle-b"), ("cycle-b", "cycle-a")):
            entry = zipfile.ZipInfo("CodexRadar.app/" + name)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, target)
    elif injection == "root-not-directory":
        archive.writestr("CodexRadar.app", b"not a directory")
    elif injection == "overlapping-range":
        archive.writestr("CodexRadar.app/overlap-a", b"a")
        archive.writestr("CodexRadar.app/overlap-b", b"b")
    elif injection == "oversized-archive":
        pass
    else:
        raise SystemExit("unknown archive injection")

if injection == "overlapping-range":
    data = bytearray(open(archive_path, "rb").read())
    eocd = data.rfind(b"PK\x05\x06")
    entry_count = struct.unpack_from("<H", data, eocd + 10)[0]
    offset = struct.unpack_from("<I", data, eocd + 16)[0]
    central_entries = {}
    for _ in range(entry_count):
        if data[offset:offset + 4] != b"PK\x01\x02":
            raise SystemExit("invalid fixture central directory")
        name_length, extra_length, comment_length = struct.unpack_from(
            "<HHH", data, offset + 28
        )
        name = bytes(data[offset + 46:offset + 46 + name_length]).decode("utf-8")
        central_entries[name] = offset
        offset += 46 + name_length + extra_length + comment_length
    first_offset = struct.unpack_from(
        "<I", data, central_entries["CodexRadar.app/overlap-a"] + 42
    )[0]
    struct.pack_into(
        "<I", data, central_entries["CodexRadar.app/overlap-b"] + 42, first_offset
    )
    with open(archive_path, "wb") as output:
        output.write(data)
elif injection == "oversized-archive":
    with open(archive_path, "ab") as output:
        output.truncate(193 * 1024 * 1024)
PYTHON
fi
MOCK_DITTO
  chmod +x "$release_root/bin/ditto"
  printf 'preserve fixture root\n' >"$release_root/root-marker"
  /bin/realpath "$release_root"
}

run_release_fixture() {
  local release_root="$1"
  shift

  env PACKAGE_RELEASE_TEST_APP_SOURCE="$valid_verify_fixture/CodexRadar.app" \
    PACKAGE_RELEASE_DITTO_EXECUTABLE="$release_root/bin/ditto" \
    PACKAGE_RELEASE_REAL_DITTO=/usr/bin/ditto "$@" \
    "$release_root/script/package_release.sh" \
    --output "$release_root/output" --signing-mode adhoc
}

for archive_injection in extra-top-level apple-double path-traversal escaped-symlink \
  high-compression-symlink oversized-symlink oversized-regular oversized-total \
  oversized-compressed oversized-archive many-entries case-collision \
  unicode-collision ancestry-conflict symlink-ancestor symlink-cycle \
  root-not-directory overlapping-range; do
  archive_fixture="$(setup_release_fixture "$archive_injection")"
  extract_marker="$archive_fixture/extraction-started"
  mkdir -m 700 "$archive_fixture/tmp"
  case "$archive_injection" in
    extra-top-level) archive_message="archive contains an unexpected top-level entry" ;;
    apple-double) archive_message="archive contains AppleDouble metadata" ;;
    path-traversal) archive_message="archive contains an unsafe path" ;;
    escaped-symlink) archive_message="archive symlink escapes application" ;;
    high-compression-symlink) archive_message="archive entry exceeds compression ratio limit" ;;
    oversized-symlink) archive_message="archive symlink payload is too large" ;;
    oversized-regular) archive_message="archive entry exceeds uncompressed size limit" ;;
    oversized-total) archive_message="archive exceeds total uncompressed size limit" ;;
    oversized-compressed) archive_message="archive exceeds cumulative compressed size limit" ;;
    oversized-archive) archive_message="release archive exceeds byte length limit" ;;
    many-entries) archive_message="archive contains too many entries" ;;
    case-collision|unicode-collision) archive_message="archive contains a macOS path collision" ;;
    ancestry-conflict) archive_message="archive contains a file-directory ancestry conflict" ;;
    symlink-ancestor) archive_message="archive entry is nested beneath a symlink" ;;
    symlink-cycle) archive_message="archive contains an unsafe symlink cycle" ;;
    root-not-directory) archive_message="archive application root must be a directory" ;;
    overlapping-range) archive_message="archive contains overlapping local data ranges" ;;
  esac
  assert_task6_rejected "$archive_message" "$archive_fixture" \
    run_release_fixture "$archive_fixture" \
    PACKAGE_RELEASE_ARCHIVE_INJECTION="$archive_injection" \
    PACKAGE_RELEASE_EXTRACT_MARKER="$extract_marker" TMPDIR="$archive_fixture/tmp"
  [[ ! -e "$extract_marker" ]] ||
    fail "unsafe archive was extracted before validation"
  [[ -z "$(/usr/bin/find "$archive_fixture/tmp" -mindepth 1 -print -quit)" ]] ||
    fail "rejected archive retained temporary release state"
done

extraction_failure_fixture="$(setup_release_fixture extraction-failure-marker)"
extraction_marker="$extraction_failure_fixture/extraction-started"
mkdir -m 700 "$extraction_failure_fixture/tmp"
assert_task6_rejected "injected extraction failure" "$extraction_failure_fixture" \
  run_release_fixture "$extraction_failure_fixture" \
  PACKAGE_RELEASE_FAIL_EXTRACTION=true \
  PACKAGE_RELEASE_EXTRACT_MARKER="$extraction_marker" \
  TMPDIR="$extraction_failure_fixture/tmp"
[[ -f "$extraction_marker" ]] ||
  fail "extraction marker was not recorded before invoking ditto"
[[ -z "$(/usr/bin/find "$extraction_failure_fixture/tmp" -mindepth 1 -print -quit)" ]] ||
  fail "failed extraction retained temporary release state"

release_success_fixture="$(setup_release_fixture success)"
release_output="$(run_release_fixture "$release_success_fixture" 2>&1)" || {
  echo "$release_output" >&2
  fail "valid package_release fixture failed"
}
[[ "$release_output" == *"locally signed with an ad-hoc identity"* ]] ||
  fail "ad-hoc release disclosure is missing"
release_archive="$release_success_fixture/output/$CURRENT_RELEASE_BASENAME.zip"
release_checksum="$release_archive.sha256"
release_manifest="$release_archive.manifest"
[[ -f "$release_archive" && -f "$release_checksum" && -f "$release_manifest" ]] ||
  fail "package_release did not write the complete release artifact set"
checksum_basename="$(/usr/bin/basename "$release_checksum")"
archive_basename="$(/usr/bin/basename "$release_archive")"
grep -Eq "^[0-9a-f]{64}  ${archive_basename}$" "$release_checksum" ||
  fail "release checksum does not contain an artifact-relative basename"
(
  cd "$(/usr/bin/dirname "$release_checksum")"
  /usr/bin/shasum -a 256 --check "$checksum_basename" >/dev/null
) || fail "release checksum failed in its artifact directory"
portable_checksum_dir="$release_success_fixture/portable-checksum"
mkdir "$portable_checksum_dir"
cp "$release_archive" "$release_checksum" "$release_manifest" "$portable_checksum_dir/"
(
  cd "$portable_checksum_dir"
  /usr/bin/shasum -a 256 --check "$checksum_basename" >/dev/null
) || fail "release checksum is not portable with the artifact set"
grep -Fx "archive_name=$CURRENT_RELEASE_BASENAME.zip" "$release_manifest" >/dev/null
grep -Fx "version=$CURRENT_MARKETING_VERSION" "$release_manifest" >/dev/null
grep -Fx "build=$CURRENT_BUILD_NUMBER" "$release_manifest" >/dev/null
grep -Eq '^byte_length=[1-9][0-9]*$' "$release_manifest"
grep -Eq '^sha256=[0-9a-f]{64}$' "$release_manifest"
grep -Fx 'signing_mode=adhoc' "$release_manifest" >/dev/null
grep -Fx 'distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted' \
  "$release_manifest" >/dev/null
assert_fixture_root_preserved "$release_success_fixture"

assert_release_artifact_set_absent() {
  local release_root="$1"
  local archive="$release_root/output/$CURRENT_RELEASE_BASENAME.zip"

  for artifact in "$archive" "$archive.sha256" "$archive.manifest"; do
    [[ ! -e "$artifact" && ! -L "$artifact" ]] ||
      fail "failed publication retained a release artifact: $artifact"
  done
  if [[ -d "$release_root/output" ]]; then
    [[ -z "$(/usr/bin/find "$release_root/output" -mindepth 1 -maxdepth 1 \
      -name '.CodexRadar.release.stage.*' -print -quit)" ]] ||
      fail "failed publication retained a hidden release stage"
  fi
}

publish_failure_fixture="$(setup_release_fixture publish-failure)"
assert_task6_rejected "injected release publish failure at artifact 2" \
  "$publish_failure_fixture" run_release_fixture "$publish_failure_fixture" \
  PACKAGE_RELEASE_TEST_FAIL_PUBLISH_INDEX=2
assert_release_artifact_set_absent "$publish_failure_fixture"

signal_failure_fixture="$(setup_release_fixture publish-signal)"
assert_task6_rejected "release publishing interrupted" "$signal_failure_fixture" \
  run_release_fixture "$signal_failure_fixture" \
  PACKAGE_RELEASE_TEST_SIGNAL_AFTER_PUBLISH_COUNT=1
assert_release_artifact_set_absent "$signal_failure_fixture"

critical_signal_fixture="$(setup_release_fixture publish-critical-signal)"
critical_signal_control="$critical_signal_fixture/control"
mkdir "$critical_signal_control" "$critical_signal_fixture/output"
printf 'prior archive\n' >"$critical_signal_fixture/output/Prior-v0.0.1.zip"
printf 'prior checksum\n' >"$critical_signal_fixture/output/Prior-v0.0.1.zip.sha256"
printf 'prior manifest\n' >"$critical_signal_fixture/output/Prior-v0.0.1.zip.manifest"
/usr/bin/shasum -a 256 \
  "$critical_signal_fixture/output/Prior-v0.0.1.zip" \
  "$critical_signal_fixture/output/Prior-v0.0.1.zip.sha256" \
  "$critical_signal_fixture/output/Prior-v0.0.1.zip.manifest" \
  >"$critical_signal_fixture/prior-before.sha256"
env PACKAGE_RELEASE_TEST_APP_SOURCE="$valid_verify_fixture/CodexRadar.app" \
  PACKAGE_RELEASE_DITTO_EXECUTABLE="$critical_signal_fixture/bin/ditto" \
  PACKAGE_RELEASE_REAL_DITTO=/usr/bin/ditto \
  PACKAGE_RELEASE_TEST_HELPER_PAUSE_READY="$critical_signal_control/ready" \
  PACKAGE_RELEASE_TEST_HELPER_PAUSE_CONTINUE="$critical_signal_control/continue" \
  "$critical_signal_fixture/script/package_release.sh" \
  --output "$critical_signal_fixture/output" --signing-mode adhoc \
  >"$critical_signal_fixture/publisher.log" 2>&1 &
critical_publisher_pid=$!
critical_publisher_ready=false
for _ in $(seq 1 1000); do
  if [[ -f "$critical_signal_control/ready" ]]; then
    critical_publisher_ready=true
    break
  fi
  /bin/sleep 0.01
done
if [[ "$critical_publisher_ready" != true ]]; then
  /bin/kill -TERM "$critical_publisher_pid" >/dev/null 2>&1 || true
  wait "$critical_publisher_pid" >/dev/null 2>&1 || true
  cat "$critical_signal_fixture/publisher.log" >&2
  fail "release helper did not pause in the publish rename critical window"
fi
/bin/kill -TERM "$critical_publisher_pid"
: >"$critical_signal_control/continue"
critical_publisher_status=0
wait "$critical_publisher_pid" || critical_publisher_status=$?
[[ "$critical_publisher_status" -eq 130 ]] || {
  cat "$critical_signal_fixture/publisher.log" >&2
  fail "deferred publish signal did not exit with status 130"
}
grep -F "release publishing interrupted" \
  "$critical_signal_fixture/publisher.log" >/dev/null ||
  fail "deferred publish signal was not reported"
assert_release_artifact_set_absent "$critical_signal_fixture"
/usr/bin/shasum -a 256 --check \
  "$critical_signal_fixture/prior-before.sha256" >/dev/null ||
  fail "publish signal rollback changed a prior artifact set"
critical_retry_output="$(run_release_fixture "$critical_signal_fixture" 2>&1)" || {
  echo "$critical_retry_output" >&2
  fail "release output lock was not released after deferred signal rollback"
}
/usr/bin/shasum -a 256 --check \
  "$critical_signal_fixture/prior-before.sha256" >/dev/null ||
  fail "successful retry changed a prior artifact set"

post_rename_signal_fixture="$(setup_release_fixture publish-post-rename-signal)"
post_rename_control="$post_rename_signal_fixture/control"
mkdir "$post_rename_control" "$post_rename_signal_fixture/output"
printf 'prior archive\n' >"$post_rename_signal_fixture/output/Prior-v0.0.1.zip"
printf 'prior checksum\n' >"$post_rename_signal_fixture/output/Prior-v0.0.1.zip.sha256"
printf 'prior manifest\n' >"$post_rename_signal_fixture/output/Prior-v0.0.1.zip.manifest"
/usr/bin/shasum -a 256 \
  "$post_rename_signal_fixture/output/Prior-v0.0.1.zip" \
  "$post_rename_signal_fixture/output/Prior-v0.0.1.zip.sha256" \
  "$post_rename_signal_fixture/output/Prior-v0.0.1.zip.manifest" \
  >"$post_rename_signal_fixture/prior-before.sha256"
env PACKAGE_RELEASE_TEST_APP_SOURCE="$valid_verify_fixture/CodexRadar.app" \
  PACKAGE_RELEASE_DITTO_EXECUTABLE="$post_rename_signal_fixture/bin/ditto" \
  PACKAGE_RELEASE_REAL_DITTO=/usr/bin/ditto \
  PACKAGE_RELEASE_TEST_HELPER_PAUSE_AFTER_RENAME_READY="$post_rename_control/ready" \
  PACKAGE_RELEASE_TEST_HELPER_PAUSE_AFTER_RENAME_CONTINUE="$post_rename_control/continue" \
  /usr/bin/python3 -c \
  'import os, sys
child_pid = os.fork()
if child_pid:
    with open(sys.argv[1], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(child_pid))
    _, status = os.waitpid(child_pid, 0)
    if os.WIFEXITED(status):
        sys.exit(os.WEXITSTATUS(status))
    if os.WIFSIGNALED(status):
        sys.exit(128 + os.WTERMSIG(status))
    sys.exit(1)
os.setsid()
os.execv(sys.argv[2], sys.argv[2:])' \
  "$post_rename_control/publisher.pid" \
  "$post_rename_signal_fixture/script/package_release.sh" \
  --output "$post_rename_signal_fixture/output" --signing-mode adhoc \
  >"$post_rename_signal_fixture/publisher.log" 2>&1 &
post_rename_publisher_wrapper_pid=$!
post_rename_ready=false
for _ in $(seq 1 1000); do
  if [[ -f "$post_rename_control/ready" ]]; then
    post_rename_ready=true
    break
  fi
  /bin/sleep 0.01
done
if [[ "$post_rename_ready" != true ]]; then
  if [[ -f "$post_rename_control/publisher.pid" ]]; then
    post_rename_publisher_pid="$(<"$post_rename_control/publisher.pid")"
    /bin/kill -TERM -- "-$post_rename_publisher_pid" >/dev/null 2>&1 || true
  else
    /bin/kill -TERM "$post_rename_publisher_wrapper_pid" >/dev/null 2>&1 || true
  fi
  wait "$post_rename_publisher_wrapper_pid" >/dev/null 2>&1 || true
  cat "$post_rename_signal_fixture/publisher.log" >&2
  fail "release helper did not pause after the publish rename"
fi
post_rename_publisher_pid="$(<"$post_rename_control/publisher.pid")"
post_rename_archive="$post_rename_signal_fixture/output/$CURRENT_RELEASE_BASENAME.zip"
[[ -f "$post_rename_archive" ]] ||
  fail "post-rename pause occurred before the release artifact rename"
/bin/kill -TERM -- "-$post_rename_publisher_pid"
post_rename_publisher_status=0
wait "$post_rename_publisher_wrapper_pid" || post_rename_publisher_status=$?
[[ "$post_rename_publisher_status" -eq 130 ]] || {
  cat "$post_rename_signal_fixture/publisher.log" >&2
  fail "post-rename process-group signal did not exit with status 130"
}
grep -F "release publishing interrupted" \
  "$post_rename_signal_fixture/publisher.log" >/dev/null ||
  fail "post-rename process-group signal was not reported"
assert_release_artifact_set_absent "$post_rename_signal_fixture"
/usr/bin/shasum -a 256 --check \
  "$post_rename_signal_fixture/prior-before.sha256" >/dev/null ||
  fail "post-rename rollback changed a prior artifact set"
run_release_fixture "$post_rename_signal_fixture" >/dev/null 2>&1 ||
  fail "release output lock was not released after post-rename helper death"
/usr/bin/shasum -a 256 --check \
  "$post_rename_signal_fixture/prior-before.sha256" >/dev/null ||
  fail "post-rename retry changed a prior artifact set"

existing_artifact_fixture="$(setup_release_fixture preserve-existing-release)"
existing_archive="$existing_artifact_fixture/output/$CURRENT_RELEASE_BASENAME.zip"
mkdir "$existing_artifact_fixture/output"
printf 'existing archive\n' >"$existing_archive"
printf 'existing checksum\n' >"$existing_archive.sha256"
printf 'existing manifest\n' >"$existing_archive.manifest"
/usr/bin/shasum -a 256 "$existing_archive" "$existing_archive.sha256" \
  "$existing_archive.manifest" >"$existing_artifact_fixture/before-existing.sha256"
assert_task6_rejected "release artifact already exists" "$existing_artifact_fixture" \
  run_release_fixture "$existing_artifact_fixture"
/usr/bin/shasum -a 256 --check \
  "$existing_artifact_fixture/before-existing.sha256" >/dev/null ||
  fail "failed publication changed a pre-existing release artifact"

concurrent_fixture="$(setup_release_fixture concurrent-publish)"
concurrent_control="$concurrent_fixture/control"
mkdir "$concurrent_control"
run_release_fixture "$concurrent_fixture" \
  PACKAGE_RELEASE_TEST_PAUSE_AFTER_LOCK=true \
  PACKAGE_RELEASE_TEST_CONTROL_DIR="$concurrent_control" \
  >"$concurrent_fixture/first-publisher.log" 2>&1 &
first_publisher_pid=$!
publisher_ready=false
for _ in $(seq 1 1000); do
  if [[ -f "$concurrent_control/ready" ]]; then
    publisher_ready=true
    break
  fi
  /bin/sleep 0.01
done
if [[ "$publisher_ready" != true ]]; then
  /bin/kill -TERM "$first_publisher_pid" >/dev/null 2>&1 || true
  wait "$first_publisher_pid" >/dev/null 2>&1 || true
  cat "$concurrent_fixture/first-publisher.log" >&2
  fail "first release publisher did not acquire the stable output lock"
fi
assert_task6_rejected "output path is locked by another packager" \
  "$concurrent_fixture" run_release_fixture "$concurrent_fixture"
: >"$concurrent_control/continue"
wait "$first_publisher_pid" || {
  cat "$concurrent_fixture/first-publisher.log" >&2
  fail "first release publisher failed after concurrent rejection"
}
concurrent_archive="$concurrent_fixture/output/$CURRENT_RELEASE_BASENAME.zip"
[[ -f "$concurrent_archive" && -f "$concurrent_archive.sha256" && \
  -f "$concurrent_archive.manifest" ]] ||
  fail "concurrent publication did not leave one complete artifact set"
(
  cd "$concurrent_fixture/output"
  /usr/bin/shasum -a 256 --check \
    "$(/usr/bin/basename "$concurrent_archive.sha256")" >/dev/null
) || fail "concurrent publication produced an invalid checksum"

echo "package verification fixtures passed"
