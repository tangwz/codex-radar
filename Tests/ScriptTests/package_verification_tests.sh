#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/script/package_app.sh"

fail() {
  echo "$*" >&2
  exit 1
}

[[ -f "$PACKAGE_SCRIPT" ]] || fail "package_app.sh does not exist"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
swift package dump-package >"$fixture_dir/base-package-dump.json"

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

destination_race_fixture="$(setup_fixture destination-race)"
write_update_config "$destination_race_fixture" "2.9.4" ""
install_mock_swift "$destination_race_fixture"
export PACKAGE_APP_TEST_DESTINATION_SYMLINK_RACE=true
assert_rejected "destination application must not be a symlink" "$destination_race_fixture" \
  --output "$destination_race_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false
unset PACKAGE_APP_TEST_DESTINATION_SYMLINK_RACE
[[ -L "$destination_race_fixture/dist/CodexRadar.app" ]] ||
  fail "destination race fixture did not reach the atomic helper recheck"

signal_fixture="$(setup_fixture signal-before-commit)"
write_update_config "$signal_fixture" "2.9.4" ""
install_mock_swift "$signal_fixture"
mkdir -p "$signal_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$signal_fixture/dist/CodexRadar.app/marker"
export PACKAGE_APP_TEST_SIGNAL_BEFORE_COMMIT=true
assert_rejected "packaging interrupted before commit" "$signal_fixture" \
  --output "$signal_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false
unset PACKAGE_APP_TEST_SIGNAL_BEFORE_COMMIT
[[ "$(cat "$signal_fixture/dist/CodexRadar.app/marker")" == "old artifact" ]] ||
  fail "signal before commit replaced the existing application"

cleanup_fixture="$(setup_fixture cleanup-failure)"
write_update_config "$cleanup_fixture" "2.9.4" ""
install_mock_swift "$cleanup_fixture"
mkdir -p "$cleanup_fixture/dist/CodexRadar.app"
printf 'old artifact\n' >"$cleanup_fixture/dist/CodexRadar.app/marker"
export PACKAGE_APP_TEST_CLEANUP_FAILURE=true
assert_succeeds "$cleanup_fixture" \
  --output "$cleanup_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false
unset PACKAGE_APP_TEST_CLEANUP_FAILURE
[[ -f "$cleanup_fixture/dist/CodexRadar.app/Contents/MacOS/CodexRadar" ]] ||
  fail "cleanup failure did not leave the committed application"
old_staging_count="$(find "$cleanup_fixture/dist" -maxdepth 1 -name '.CodexRadar.app.package.*' | wc -l | tr -d ' ')"
[[ "$old_staging_count" == 1 ]] || fail "cleanup failure fixture did not preserve old staging for later cleanup"

echo "package verification fixtures passed"
