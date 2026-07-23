#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_SPARKLE_URL="https://github.com/sparkle-project/Sparkle"
EXPECTED_SPARKLE_REVISION="b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
EXPECTED_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"
COPYRIGHT="© 2026 Terence Tang. All rights reserved."

usage() {
  echo "usage: $0 --output PATH --configuration debug|release --architectures ARCH_LIST --updates-enabled true|false" >&2
  return 2
}

load_update_config() {
  local config_path="$1" line key value
  local seen_sparkle_version=false
  local seen_public_key=false
  local seen_feed_url=false

  SPARKLE_VERSION=""
  SPARKLE_PUBLIC_ED_KEY=""
  PRODUCTION_FEED_URL=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || die "invalid update config line" || return 1
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      SPARKLE_VERSION)
        [[ "$seen_sparkle_version" == false ]] || die "duplicate SPARKLE_VERSION" || return 1
        seen_sparkle_version=true
        SPARKLE_VERSION="$value"
        ;;
      SPARKLE_PUBLIC_ED_KEY)
        [[ "$seen_public_key" == false ]] || die "duplicate SPARKLE_PUBLIC_ED_KEY" || return 1
        seen_public_key=true
        SPARKLE_PUBLIC_ED_KEY="$value"
        ;;
      PRODUCTION_FEED_URL)
        [[ "$seen_feed_url" == false ]] || die "duplicate PRODUCTION_FEED_URL" || return 1
        seen_feed_url=true
        PRODUCTION_FEED_URL="$value"
        ;;
      *) die "unknown update key: $key" || return 1 ;;
    esac
  done <"$config_path"

  [[ "$SPARKLE_VERSION" == "$EXPECTED_SPARKLE_VERSION" ]] ||
    die "SPARKLE_VERSION must equal $EXPECTED_SPARKLE_VERSION" || return 1
  [[ "$PRODUCTION_FEED_URL" == "$EXPECTED_FEED_URL" ]] ||
    die "PRODUCTION_FEED_URL must equal $EXPECTED_FEED_URL" || return 1
}

validate_sparkle_dependency() {
  local swift_executable="$1" package_dump_path="$2" resolved_path="$3"
  local dependency_count dependency_index identity url exact_count exact_version sparkle_dependency_count
  local pin_count pin_index pin_location pin_version pin_revision sparkle_pin_count

  "$swift_executable" package --package-path "$ROOT_DIR" dump-package >"$package_dump_path"
  dependency_count="$(/usr/bin/plutil -extract dependencies raw "$package_dump_path")"
  sparkle_dependency_count=0
  dependency_index=0
  while [[ "$dependency_index" -lt "$dependency_count" ]]; do
    identity="$(/usr/bin/plutil -extract "dependencies.$dependency_index.sourceControl.0.identity" raw \
      "$package_dump_path" 2>/dev/null || true)"
    if [[ "$identity" == sparkle ]]; then
      sparkle_dependency_count=$((sparkle_dependency_count + 1))
      url="$(/usr/bin/plutil -extract "dependencies.$dependency_index.sourceControl.0.location.remote.0.urlString" raw \
        "$package_dump_path" 2>/dev/null || true)"
      [[ "$url" == "$EXPECTED_SPARKLE_URL" ]] ||
        die "Package.swift must contain exactly one official Sparkle dependency" || return 1
      exact_count="$(/usr/bin/plutil -extract "dependencies.$dependency_index.sourceControl.0.requirement.exact" raw \
        "$package_dump_path" 2>/dev/null || true)"
      exact_version="$(/usr/bin/plutil -extract "dependencies.$dependency_index.sourceControl.0.requirement.exact.0" raw \
        "$package_dump_path" 2>/dev/null || true)"
      [[ "$exact_count" == 1 && "$exact_version" == "$EXPECTED_SPARKLE_VERSION" ]] ||
        die "Sparkle dependency must use exact version $EXPECTED_SPARKLE_VERSION" || return 1
    fi
    dependency_index=$((dependency_index + 1))
  done
  [[ "$sparkle_dependency_count" -eq 1 ]] ||
    die "Package.swift must contain exactly one official Sparkle dependency" || return 1

  pin_count="$(/usr/bin/plutil -extract pins raw "$resolved_path")"
  sparkle_pin_count=0
  sparkle_pin_valid=true
  pin_index=0
  while [[ "$pin_index" -lt "$pin_count" ]]; do
    identity="$(/usr/bin/plutil -extract "pins.$pin_index.identity" raw "$resolved_path" 2>/dev/null || true)"
    if [[ "$identity" == sparkle ]]; then
      sparkle_pin_count=$((sparkle_pin_count + 1))
      pin_location="$(/usr/bin/plutil -extract "pins.$pin_index.location" raw "$resolved_path" 2>/dev/null || true)"
      pin_version="$(/usr/bin/plutil -extract "pins.$pin_index.state.version" raw "$resolved_path" 2>/dev/null || true)"
      pin_revision="$(/usr/bin/plutil -extract "pins.$pin_index.state.revision" raw "$resolved_path" 2>/dev/null || true)"
      if [[ "$pin_location" != "$EXPECTED_SPARKLE_URL" || \
        "$pin_version" != "$EXPECTED_SPARKLE_VERSION" || \
        "$pin_revision" != "$EXPECTED_SPARKLE_REVISION" ]]; then
        sparkle_pin_valid=false
      fi
    fi
    pin_index=$((pin_index + 1))
  done
  [[ "$sparkle_pin_count" -eq 1 ]] ||
    die "Package.resolved must contain exactly one Sparkle pin" || return 1
  [[ "$sparkle_pin_valid" == true ]] ||
    die "Package.resolved Sparkle pin does not match the approved lock" || return 1
}

validate_public_key() {
  local decoded_path="$1" decoded_size

  [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  if ! printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D >"$decoded_path" 2>/dev/null; then
    die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  fi
  decoded_size="$(/usr/bin/wc -c <"$decoded_path" | /usr/bin/tr -d ' ')"
  [[ "$decoded_size" == "32" ]] || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
}

normalize_resources() {
  local resource_root="$1" output_path="$2" relative_path digest target mode

  : >"$output_path"
  while IFS= read -r -d '' relative_path; do
    if [[ -L "$resource_root/$relative_path" ]]; then
      target="$(/usr/bin/readlink "$resource_root/$relative_path")"
      mode="$(/usr/bin/stat -f '%Lp' "$resource_root/$relative_path")"
      printf 'path\0%s\0type\0link\0target\0%s\0mode\0%s\0' "$relative_path" "$target" "$mode" >>"$output_path"
    elif [[ -d "$resource_root/$relative_path" ]]; then
      mode="$(/usr/bin/stat -f '%Lp' "$resource_root/$relative_path")"
      printf 'path\0%s\0type\0directory\0mode\0%s\0' "$relative_path" "$mode" >>"$output_path"
    elif [[ -f "$resource_root/$relative_path" ]]; then
      digest="$(/usr/bin/shasum -a 256 "$resource_root/$relative_path" | /usr/bin/awk '{print $1}')"
      mode="$(/usr/bin/stat -f '%Lp' "$resource_root/$relative_path")"
      printf 'path\0%s\0type\0file\0sha256\0%s\0mode\0%s\0' "$relative_path" "$digest" "$mode" >>"$output_path"
    else
      die "unsupported resource entry: $relative_path" || return 1
    fi
  done < <(
    cd "$resource_root"
    /usr/bin/find -s . -mindepth 1 -print0
  )
}

validate_framework_tree() {
  local framework_path="$1" framework_real current_path link_path target_real

  [[ -d "$framework_path" && ! -L "$framework_path" ]] ||
    die "Sparkle.framework must be a real directory" || return 1
  framework_real="$(/bin/realpath "$framework_path")"
  current_path="$framework_path/Versions/Current"
  [[ -L "$current_path" ]] || die "Sparkle.framework Versions/Current must be a symlink" || return 1

  while IFS= read -r -d '' link_path; do
    target_real="$(/bin/realpath "$link_path" 2>/dev/null)" ||
      die "unresolved Sparkle.framework symlink: $link_path" || return 1
    case "$target_real" in
      "$framework_real"|"$framework_real"/*) ;;
      *) die "escaped Sparkle.framework symlink: $link_path" || return 1 ;;
    esac
  done < <(/usr/bin/find -s "$framework_path" -type l -print0)
}

assert_framework_version() {
  local framework_path="$1" framework_version

  framework_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    "$framework_path/Versions/Current/Resources/Info.plist")"
  [[ "$framework_version" == "$EXPECTED_SPARKLE_VERSION" ]] ||
    die "embedded Sparkle.framework must equal $EXPECTED_SPARKLE_VERSION" || return 1
}

assert_framework_rpath() {
  local executable_path="$1" architecture="$2"

  "$OTOOL_EXECUTABLE" -arch "$architecture" -l "$executable_path" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
      if ($2 == "@executable_path/../Frameworks") found = 1
      in_rpath = 0
    }
    END { exit(found ? 0 : 1) }
  ' || die "missing LC_RPATH @executable_path/../Frameworks for $architecture" || return 1
}

assert_architecture_set() {
  local executable_path="$1" failure_message="$2"
  shift 2
  local actual_architectures architecture expected_architecture found

  actual_architectures="$("$LIPO_EXECUTABLE" -archs "$executable_path")" || die "$failure_message" || return 1
  [[ "$(printf '%s\n' $actual_architectures | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq "$#" ]] ||
    die "$failure_message" || return 1
  for expected_architecture in "$@"; do
    found=false
    for architecture in $actual_architectures; do
      [[ "$architecture" != "$expected_architecture" ]] || found=true
    done
    [[ "$found" == true ]] || die "$failure_message" || return 1
  done
}

write_info_plist() {
  local plist_path="$1" updates_enabled="$2"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/bin/plutil -insert CFBundleExecutable -string "$APP_NAME" "$plist_path"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$plist_path"
  /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$plist_path"
  /usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$plist_path"
  /usr/bin/plutil -insert CFBundleLocalizations -json '["en","zh-Hans"]' "$plist_path"
  /usr/bin/plutil -insert CFBundleName -string "Codex Radar" "$plist_path"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$plist_path"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$plist_path"
  /usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$plist_path"
  /usr/bin/plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$plist_path"
  /usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.developer-tools "$plist_path"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$plist_path"
  /usr/bin/plutil -insert LSUIElement -bool true "$plist_path"
  /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$plist_path"

  if [[ "$updates_enabled" == true ]]; then
    /usr/bin/plutil -insert SUFeedURL -string "$PRODUCTION_FEED_URL" "$plist_path"
    /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$plist_path"
    /usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "$plist_path"
    /usr/bin/plutil -insert SUAutomaticallyUpdate -bool true "$plist_path"
    /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$plist_path"
    /usr/bin/plutil -insert SURequireSignedFeed -bool true "$plist_path"
    /usr/bin/plutil -insert CodexRadarUpdatesEnabled -bool true "$plist_path"
  else
    /usr/bin/plutil -insert CodexRadarUpdatesEnabled -bool false "$plist_path"
  fi

  /usr/bin/plutil -lint "$plist_path" >/dev/null
}

output_path=""
configuration=""
architecture_list=""
updates_enabled=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      [[ -z "$output_path" && "$#" -ge 2 ]] || usage
      output_path="$2"
      shift 2
      ;;
    --configuration)
      [[ -z "$configuration" && "$#" -ge 2 ]] || usage
      configuration="$2"
      shift 2
      ;;
    --architectures)
      [[ -z "$architecture_list" && "$#" -ge 2 ]] || usage
      architecture_list="$2"
      shift 2
      ;;
    --updates-enabled)
      [[ -z "$updates_enabled" && "$#" -ge 2 ]] || usage
      updates_enabled="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$output_path" && -n "$configuration" && -n "$architecture_list" && -n "$updates_enabled" ]] || usage
case "$configuration" in
  debug|release) ;;
  *) die "configuration must be debug or release" ;;
esac
case "$updates_enabled" in
  true|false) ;;
  *) die "updates-enabled must be true or false" ;;
esac
if [[ "$updates_enabled" == true && "$configuration" != release ]]; then
  die "updates may only be enabled for release configuration"
fi

[[ "$architecture_list" != *$'\n'* && "$architecture_list" != *$'\r'* ]] ||
  die "architectures must be a single whitespace-separated line"
requested_architectures=()
IFS=$' \t' read -r -a requested_architectures <<<"$architecture_list"
architectures=()
for architecture in "${requested_architectures[@]}"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) die "unknown architecture: $architecture" ;;
  esac
  for existing_architecture in "${architectures[@]:-}"; do
    [[ "$existing_architecture" != "$architecture" ]] || die "duplicate architecture: $architecture"
  done
  architectures+=("$architecture")
done
[[ "${#architectures[@]}" -gt 0 ]] || die "architectures must not be empty"
if [[ "$updates_enabled" == true ]]; then
  [[ "${#architectures[@]}" -eq 2 ]] || die "updates-enabled requires exactly arm64 and x86_64"
  has_arm64=false
  has_x86_64=false
  for architecture in "${architectures[@]}"; do
    [[ "$architecture" != arm64 ]] || has_arm64=true
    [[ "$architecture" != x86_64 ]] || has_x86_64=true
  done
  [[ "$has_arm64" == true && "$has_x86_64" == true ]] ||
    die "updates-enabled requires exactly arm64 and x86_64"
fi

load_version_config "$ROOT_DIR/version.env"
load_update_config "$ROOT_DIR/config/update.env"

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-package.XXXXXX")"
delivery_path=""
destination_path=""
output_lock_path=""
output_lock_acquired=false
lock_process_id=""
lock_pipe_open=false
committed=false
cleanup() {
  set +e
  if [[ "$committed" == false && -n "$delivery_path" && \
    (-e "$delivery_path" || -L "$delivery_path") && \
    -n "${delivery_device:-}" && -n "${delivery_inode:-}" ]]; then
    "$atomic_swap_executable" remove "$output_path" "$delivery_name" \
      "$output_device" "$output_inode" "$delivery_device" "$delivery_inode" \
      >/dev/null 2>&1 || true
  fi
  if [[ "$lock_pipe_open" == true ]]; then
    exec 9>&-
    lock_pipe_open=false
  fi
  [[ -z "$lock_process_id" ]] || wait "$lock_process_id" >/dev/null 2>&1 || true
  /bin/rm -rf "$work_dir" >/dev/null 2>&1 || true
  return 0
}
handle_signal() {
  echo "packaging interrupted before commit" >&2
  exit 130
}
pause_for_test() {
  local phase="$1" control_dir="${PACKAGE_APP_TEST_CONTROL_DIR:-}"

  [[ "${PACKAGE_APP_TEST_PAUSE_PHASE:-}" == "$phase" ]] || return 0
  [[ -n "$control_dir" && -d "$control_dir" && ! -L "$control_dir" ]] ||
    die "invalid package test control directory" || return 1
  : >"$control_dir/ready"
  while [[ ! -e "$control_dir/continue" ]]; do
    /bin/sleep 0.01
  done
}
trap cleanup EXIT
trap handle_signal HUP INT TERM

swift_executable="$(command -v swift 2>/dev/null || true)"
[[ -n "$swift_executable" ]] || die "swift is required"
LIPO_EXECUTABLE="${PACKAGE_APP_LIPO_EXECUTABLE:-/usr/bin/lipo}"
OTOOL_EXECUTABLE="${PACKAGE_APP_OTOOL_EXECUTABLE:-/usr/bin/otool}"
[[ -x "$LIPO_EXECUTABLE" ]] || die "lipo is required"
[[ -x "$OTOOL_EXECUTABLE" ]] || die "otool is required"
validate_sparkle_dependency "$swift_executable" "$work_dir/package-dump.json" "$ROOT_DIR/Package.resolved"

atomic_swap_source="$ROOT_DIR/script/helpers/atomic_swap.c"
atomic_swap_executable="$work_dir/atomic-swap"
[[ -f "$atomic_swap_source" ]] || die "missing atomic swap helper source"
/usr/bin/xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
  -mmacosx-version-min="$MIN_SYSTEM_VERSION" "$atomic_swap_source" -o "$atomic_swap_executable"

if [[ "$updates_enabled" == true ]]; then
  validate_public_key "$work_dir/public-key.bin"
fi

binaries=()
resource_bundles=()
bin_paths=()
resource_manifests=()
for architecture in "${architectures[@]}"; do
  scratch_path="$work_dir/scratch-$architecture"
  target_triple="$architecture-apple-macosx$MIN_SYSTEM_VERSION"
  "$swift_executable" build \
    --package-path "$ROOT_DIR" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --scratch-path "$scratch_path" \
    --disable-automatic-resolution \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks'
  bin_path="$("$swift_executable" build \
    --package-path "$ROOT_DIR" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --scratch-path "$scratch_path" \
    --disable-automatic-resolution \
    --show-bin-path)"
  binary_path="$bin_path/$APP_NAME"
  resource_bundle="$bin_path/$RESOURCE_BUNDLE_NAME"
  [[ -f "$binary_path" && -x "$binary_path" ]] || die "missing executable for $architecture"
  [[ -d "$resource_bundle" ]] || die "missing resource bundle for $architecture"
  assert_architecture_set "$binary_path" "input executable architecture mismatch for $architecture" "$architecture"

  resource_manifest="$work_dir/resources-$architecture.txt"
  normalize_resources "$resource_bundle" "$resource_manifest"
  binaries+=("$binary_path")
  resource_bundles+=("$resource_bundle")
  bin_paths+=("$bin_path")
  resource_manifests+=("$resource_manifest")
done

reference_manifest="${resource_manifests[0]}"
for resource_manifest in "${resource_manifests[@]:1}"; do
  /usr/bin/cmp -s "$reference_manifest" "$resource_manifest" ||
    die "resource sets differ between architectures"
done

staged_app="$work_dir/$APP_NAME.app"
contents_path="$staged_app/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
frameworks_path="$contents_path/Frameworks"
executable_path="$macos_path/$APP_NAME"
/bin/mkdir -p "$macos_path" "$resources_path" "$frameworks_path"
/bin/chmod 0755 "$staged_app"

"$LIPO_EXECUTABLE" -create "${binaries[@]}" -output "$executable_path"
/bin/chmod +x "$executable_path"
assert_architecture_set "$executable_path" "merged executable architecture mismatch" "${architectures[@]}"
/usr/bin/ditto "${resource_bundles[0]}" "$resources_path"

sparkle_frameworks=()
for bin_path in "${bin_paths[@]}"; do
  framework_matches=()
  while IFS= read -r -d '' framework_path; do
    framework_matches+=("$framework_path")
  done < <(/usr/bin/find -s "$bin_path" -type d -name Sparkle.framework -prune -print0)
  [[ "${#framework_matches[@]}" -eq 1 ]] ||
    die "expected exactly one SwiftPM Sparkle.framework, found ${#framework_matches[@]} in $bin_path"

  sparkle_framework="${framework_matches[0]}"
  bin_path_real="$(/bin/realpath "$bin_path")"
  sparkle_framework_real="$(/bin/realpath "$sparkle_framework")"
  case "$sparkle_framework_real" in
    "$bin_path_real"/*) ;;
    *) die "Sparkle.framework escaped the SwiftPM product directory" ;;
  esac
  validate_framework_tree "$sparkle_framework"
  assert_framework_version "$sparkle_framework"
  sparkle_frameworks+=("$sparkle_framework")
done

/usr/bin/ditto "${sparkle_frameworks[0]}" "$frameworks_path/Sparkle.framework"
validate_framework_tree "$frameworks_path/Sparkle.framework"
assert_framework_version "$frameworks_path/Sparkle.framework"

for architecture in "${architectures[@]}"; do
  assert_framework_rpath "$executable_path" "$architecture"
done
write_info_plist "$contents_path/Info.plist" "$updates_enabled"

output_parent="$(/usr/bin/dirname "$output_path")"
output_name="$(/usr/bin/basename "$output_path")"
/bin/mkdir -p "$output_parent"
output_parent_real="$(/bin/realpath "$output_parent")"
normalized_output_path="$output_parent_real/$output_name"
[[ ! -L "$normalized_output_path" ]] || die "output directory must not be a symlink"
if [[ ! -e "$normalized_output_path" ]]; then
  /bin/mkdir "$normalized_output_path"
fi
[[ -d "$normalized_output_path" && ! -L "$normalized_output_path" ]] ||
  die "output path must be a directory"
output_path="$(/bin/realpath "$normalized_output_path")"
output_owner="$(/usr/bin/stat -f '%u' "$output_path")"
output_mode="$(/usr/bin/stat -f '%Lp' "$output_path")"
output_device="$(/usr/bin/stat -f '%d' "$output_path")"
output_inode="$(/usr/bin/stat -f '%i' "$output_path")"
[[ "$output_owner" == "$(/usr/bin/id -u)" ]] || die "output parent must be owned by the effective user"
(( (8#$output_mode & 022) == 0 )) || die "output parent must not be group or world writable"

output_lock_path="$output_path/.$APP_NAME.package.lock"
lock_fifo="$work_dir/package-lock.fifo"
lock_ready="$work_dir/package-lock.ready"
/usr/bin/mkfifo "$lock_fifo"
"$atomic_swap_executable" lock "$output_path" "$(/usr/bin/basename "$output_lock_path")" \
  "$output_device" "$output_inode" <"$lock_fifo" >"$lock_ready" 2>"$work_dir/package-lock.stderr" &
lock_process_id=$!
exec 9>"$lock_fifo"
lock_pipe_open=true
lock_attempt=0
while [[ ! -s "$lock_ready" && "$lock_attempt" -lt 200 ]]; do
  if ! /bin/kill -0 "$lock_process_id" 2>/dev/null; then
    exec 9>&-
    lock_pipe_open=false
    wait "$lock_process_id" || true
    /bin/cat "$work_dir/package-lock.stderr" >&2
    die "failed to acquire package lock"
  fi
  /bin/sleep 0.01
  lock_attempt=$((lock_attempt + 1))
done
[[ -s "$lock_ready" ]] || die "timed out acquiring package lock"
output_lock_acquired=true
pause_for_test after-lock

destination_path="$output_path/$APP_NAME.app"
[[ ! -L "$destination_path" ]] || die "destination application must not be a symlink"
delivery_path="$(/usr/bin/mktemp -d "$output_path/.$APP_NAME.app.package.XXXXXX")"
delivery_name="$(/usr/bin/basename "$delivery_path")"
/usr/bin/ditto "$staged_app" "$delivery_path"
staged_mode="$(/usr/bin/stat -f '%Lp' "$staged_app")"
/bin/chmod "$staged_mode" "$delivery_path"
delivery_device="$(/usr/bin/stat -f '%d' "$delivery_path")"
delivery_inode="$(/usr/bin/stat -f '%i' "$delivery_path")"

if [[ "${PACKAGE_APP_TEST_DESTINATION_SYMLINK_RACE:-false}" == true ]]; then
  /bin/ln -s /tmp "$destination_path"
fi
if [[ "${PACKAGE_APP_TEST_SIGNAL_BEFORE_COMMIT:-false}" == true ]]; then
  /bin/kill -TERM "$$"
fi

pause_for_test before-commit
trap '' HUP INT TERM
if [[ "${PACKAGE_APP_TEST_PAUSE_PHASE:-}" == before-rename ]]; then
  PACKAGE_APP_TEST_HELPER_PAUSE_READY="$PACKAGE_APP_TEST_CONTROL_DIR/ready" \
    PACKAGE_APP_TEST_HELPER_PAUSE_CONTINUE="$PACKAGE_APP_TEST_CONTROL_DIR/continue" \
    "$atomic_swap_executable" swap "$output_path" "$delivery_name" "$APP_NAME.app" \
      "$output_device" "$output_inode" "$delivery_device" "$delivery_inode"
else
  "$atomic_swap_executable" swap "$output_path" "$delivery_name" "$APP_NAME.app" \
    "$output_device" "$output_inode" "$delivery_device" "$delivery_inode"
fi
committed=true
printf 'Packaged %s\n' "$destination_path" || true
exit 0
