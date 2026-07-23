#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_SPARKLE_BUILD="2059"
EXPECTED_SPARKLE_MIN_SYSTEM_VERSION="10.13"
EXPECTED_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"

usage() {
  echo "usage: $0 --app PATH --architectures ARCH_LIST --updates-enabled true|false --signing-mode adhoc|developer-id" >&2
  return 2
}

load_update_config() {
  local config_path="$1" line key value
  local seen_sparkle_version=false seen_public_key=false seen_feed_url=false
  local decoded_size

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
  decoded_size="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D 2>/dev/null | \
    /usr/bin/wc -c | /usr/bin/tr -d ' ')" || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  [[ "$decoded_size" == 32 ]] || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
}

assert_real_directory() {
  local path="$1" description="$2"

  [[ -d "$path" && ! -L "$path" ]] || die "$description must be a real directory" || return 1
}

assert_real_file() {
  local path="$1" description="$2"

  [[ -f "$path" && ! -L "$path" ]] || die "$description must be a real file" || return 1
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

assert_plist_value() {
  local plist_path="$1" key="$2" expected="$3" failure_message="$4" actual

  actual="$(plist_value "$plist_path" "$key" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || die "$failure_message" || return 1
}

assert_plist_key_absent() {
  local plist_path="$1" key="$2"

  if /usr/bin/plutil -extract "$key" raw "$plist_path" >/dev/null 2>&1; then
    die "$key must be absent when updates are disabled" || return 1
  fi
}

assert_symlink_target() {
  local link_path="$1" expected_target="$2" description="$3"

  [[ -L "$link_path" ]] || die "$description must be a symlink" || return 1
  [[ "$(/usr/bin/readlink "$link_path")" == "$expected_target" ]] ||
    die "$description has an unexpected target" || return 1
}

validate_bundle_symlinks() {
  local app_path="$1" app_real link_path target_real

  app_real="$(/bin/realpath "$app_path")"
  while IFS= read -r -d '' link_path; do
    target_real="$(/bin/realpath "$link_path" 2>/dev/null)" ||
      die "unresolved bundle symlink: $link_path" || return 1
    case "$target_real" in
      "$app_real"|"$app_real"/*) ;;
      *) die "bundle symlink escapes application: $link_path" || return 1 ;;
    esac
  done < <(/usr/bin/find -s "$app_path" -type l -print0)
}

parse_architectures() {
  local architecture_list="$1" requested architecture existing

  [[ "$architecture_list" != *$'\n'* && "$architecture_list" != *$'\r'* ]] ||
    die "architectures must be a single whitespace-separated line" || return 1
  requested=()
  IFS=$' \t' read -r -a requested <<<"$architecture_list"
  EXPECTED_ARCHITECTURES=()
  for architecture in "${requested[@]}"; do
    case "$architecture" in
      arm64|x86_64) ;;
      *) die "unknown architecture: $architecture" || return 1 ;;
    esac
    for existing in "${EXPECTED_ARCHITECTURES[@]:-}"; do
      [[ "$existing" != "$architecture" ]] || die "duplicate architecture: $architecture" || return 1
    done
    EXPECTED_ARCHITECTURES+=("$architecture")
  done
  [[ "${#EXPECTED_ARCHITECTURES[@]}" -gt 0 ]] || die "architectures must not be empty" || return 1
}

assert_exact_architectures() {
  local executable_path="$1"
  shift
  local expected=("$@") actual_text architecture expected_architecture found actual_count

  actual_text="$("$LIPO_EXECUTABLE" -archs "$executable_path" 2>/dev/null)" ||
    die "unable to inspect Mach-O architectures: $executable_path" || return 1
  actual_count="$(printf '%s\n' $actual_text | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [[ "$actual_count" -eq "${#expected[@]}" ]] ||
    die "Mach-O architecture mismatch: $executable_path" || return 1
  for expected_architecture in "${expected[@]}"; do
    found=false
    for architecture in $actual_text; do
      [[ "$architecture" != "$expected_architecture" ]] || found=true
    done
    [[ "$found" == true ]] || die "Mach-O architecture mismatch: $executable_path" || return 1
  done
}

assert_macho_executable() {
  local executable_path="$1" file_description

  [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] ||
    die "missing expected executable: $executable_path" || return 1
  file_description="$("$FILE_EXECUTABLE" -b "$executable_path")" ||
    die "unable to inspect expected executable: $executable_path" || return 1
  case "$file_description" in
    Mach-O*) ;;
    *) die "expected executable is not Mach-O: $executable_path" || return 1 ;;
  esac
}

validate_sparkle_layout() {
  local app_path="$1" framework_path="$2" version_root="$3"
  local xpc_root="$version_root/XPCServices" updater_path="$version_root/Updater.app"
  local xpc_name xpc_path expected_bundle_id entry_path entry_name entry_count

  assert_real_directory "$app_path/Contents" "application Contents"
  assert_real_directory "$app_path/Contents/MacOS" "application MacOS"
  assert_real_directory "$app_path/Contents/Resources" "application Resources"
  assert_real_directory "$app_path/Contents/Frameworks" "application Frameworks"
  assert_real_directory "$framework_path" "Sparkle.framework"
  assert_real_directory "$framework_path/Versions" "Sparkle.framework Versions"
  assert_real_directory "$version_root" "Sparkle.framework Versions/B"
  assert_symlink_target "$framework_path/Versions/Current" B \
    "Sparkle.framework Versions/Current"
  for entry_name in Autoupdate Headers Modules PrivateHeaders Resources Sparkle \
    Updater.app XPCServices; do
    assert_symlink_target "$framework_path/$entry_name" \
      "Versions/Current/$entry_name" "Sparkle.framework $entry_name"
  done
  assert_real_directory "$xpc_root" "Sparkle XPCServices"
  assert_real_directory "$updater_path" "Sparkle Updater.app"
  assert_real_file "$version_root/Resources/Info.plist" "Sparkle.framework Info.plist"
  assert_real_file "$updater_path/Contents/Info.plist" "Sparkle Updater.app Info.plist"

  assert_plist_value "$version_root/Resources/Info.plist" CFBundleIdentifier \
    org.sparkle-project.Sparkle "invalid Sparkle.framework bundle identifier"
  assert_plist_value "$version_root/Resources/Info.plist" CFBundleShortVersionString \
    "$EXPECTED_SPARKLE_VERSION" "embedded Sparkle.framework must equal $EXPECTED_SPARKLE_VERSION"
  assert_plist_value "$version_root/Resources/Info.plist" CFBundleVersion \
    "$EXPECTED_SPARKLE_BUILD" "invalid Sparkle.framework build"
  assert_plist_value "$version_root/Resources/Info.plist" CFBundlePackageType \
    FMWK "invalid Sparkle.framework package type"
  assert_plist_value "$version_root/Resources/Info.plist" LSMinimumSystemVersion \
    "$EXPECTED_SPARKLE_MIN_SYSTEM_VERSION" "invalid Sparkle.framework minimum system version"
  assert_plist_value "$version_root/Resources/Info.plist" CFBundleExecutable Sparkle \
    "invalid Sparkle.framework executable declaration"
  assert_plist_value "$updater_path/Contents/Info.plist" CFBundleIdentifier \
    org.sparkle-project.Sparkle.Updater "invalid Sparkle Updater.app bundle identifier"
  assert_plist_value "$updater_path/Contents/Info.plist" CFBundleShortVersionString \
    "$EXPECTED_SPARKLE_VERSION" "Sparkle Updater.app must equal $EXPECTED_SPARKLE_VERSION"
  assert_plist_value "$updater_path/Contents/Info.plist" CFBundleVersion \
    "$EXPECTED_SPARKLE_BUILD" "invalid Sparkle Updater.app build"
  assert_plist_value "$updater_path/Contents/Info.plist" CFBundlePackageType \
    APPL "invalid Sparkle Updater.app package type"
  assert_plist_value "$updater_path/Contents/Info.plist" LSMinimumSystemVersion \
    "$EXPECTED_SPARKLE_MIN_SYSTEM_VERSION" "invalid Sparkle Updater.app minimum system version"
  assert_plist_value "$updater_path/Contents/Info.plist" CFBundleExecutable Updater \
    "invalid Sparkle Updater.app executable declaration"

  for xpc_name in Downloader Installer; do
    xpc_path="$xpc_root/$xpc_name.xpc"
    [[ -d "$xpc_path" && ! -L "$xpc_path" ]] ||
      die "missing Sparkle XPC service: $xpc_name.xpc" || return 1
    assert_real_file "$xpc_path/Contents/Info.plist" "Sparkle XPC Info.plist"
    case "$xpc_name" in
      Downloader) expected_bundle_id=org.sparkle-project.DownloaderService ;;
      Installer) expected_bundle_id=org.sparkle-project.InstallerLauncher ;;
    esac
    assert_plist_value "$xpc_path/Contents/Info.plist" CFBundleIdentifier \
      "$expected_bundle_id" "invalid Sparkle XPC bundle identifier: $xpc_name.xpc"
    assert_plist_value "$xpc_path/Contents/Info.plist" CFBundleShortVersionString \
      "$EXPECTED_SPARKLE_VERSION" "Sparkle XPC service version mismatch: $xpc_name.xpc"
    assert_plist_value "$xpc_path/Contents/Info.plist" CFBundleVersion \
      "$EXPECTED_SPARKLE_BUILD" "Sparkle XPC service build mismatch: $xpc_name.xpc"
    assert_plist_value "$xpc_path/Contents/Info.plist" CFBundlePackageType \
      'XPC!' "invalid Sparkle XPC package type: $xpc_name.xpc"
    assert_plist_value "$xpc_path/Contents/Info.plist" LSMinimumSystemVersion \
      "$EXPECTED_SPARKLE_MIN_SYSTEM_VERSION" \
      "invalid Sparkle XPC minimum system version: $xpc_name.xpc"
    assert_plist_value "$xpc_path/Contents/Info.plist" CFBundleExecutable \
      "$xpc_name" "invalid Sparkle XPC executable declaration: $xpc_name.xpc"
  done

  entry_count=0
  while IFS= read -r -d '' entry_path; do
    entry_name="$(/usr/bin/basename "$entry_path")"
    case "$entry_name" in
      Downloader.xpc|Installer.xpc) ;;
      *) die "unexpected Sparkle XPC service: $entry_name" || return 1 ;;
    esac
    entry_count=$((entry_count + 1))
  done < <(/usr/bin/find -s "$xpc_root" -mindepth 1 -maxdepth 1 -print0)
  [[ "$entry_count" -eq 2 ]] || die "Sparkle XPCServices must contain exactly two services" || return 1
}

app_argument=""
architecture_list=""
updates_enabled=""
signing_mode=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app)
      [[ -z "$app_argument" && "$#" -ge 2 ]] || usage
      app_argument="$2"
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
    --signing-mode)
      [[ -z "$signing_mode" && "$#" -ge 2 ]] || usage
      signing_mode="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[[ -n "$app_argument" && -n "$architecture_list" && -n "$updates_enabled" && -n "$signing_mode" ]] || usage
case "$updates_enabled" in
  true|false) ;;
  *) die "updates-enabled must be true or false" ;;
esac
case "$signing_mode" in
  adhoc) ;;
  developer-id)
    [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] ||
      die "developer-id verification requires DEVELOPER_ID_APPLICATION"
    [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]] ||
      die "developer-id verification requires APP_STORE_CONNECT_API_KEY_PATH"
    [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" && ! -L "$APP_STORE_CONNECT_API_KEY_PATH" ]] ||
      die "developer-id verification requires a real App Store Connect API key file"
    [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] ||
      die "developer-id verification requires APP_STORE_CONNECT_KEY_ID"
    [[ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] ||
      die "developer-id verification requires APP_STORE_CONNECT_ISSUER_ID"
    ;;
  *) die "signing-mode must be adhoc or developer-id" ;;
esac
parse_architectures "$architecture_list"
if [[ "$updates_enabled" == true ]]; then
  [[ "${#EXPECTED_ARCHITECTURES[@]}" -eq 2 ]] ||
    die "release verification requires exactly arm64 and x86_64"
  has_arm64=false
  has_x86_64=false
  for architecture in "${EXPECTED_ARCHITECTURES[@]}"; do
    [[ "$architecture" != arm64 ]] || has_arm64=true
    [[ "$architecture" != x86_64 ]] || has_x86_64=true
  done
  [[ "$has_arm64" == true && "$has_x86_64" == true ]] ||
    die "release verification requires exactly arm64 and x86_64"
else
  [[ "${#EXPECTED_ARCHITECTURES[@]}" -eq 1 ]] ||
    die "development verification requires one native main architecture"
fi

load_version_config "$ROOT_DIR/version.env"
load_update_config "$ROOT_DIR/config/update.env"
app_parent="$(/usr/bin/dirname "$app_argument")"
app_name="$(/usr/bin/basename "$app_argument")"
[[ "$app_name" == "$APP_NAME.app" ]] || die "application must be named $APP_NAME.app"
app_parent_real="$(/bin/realpath "$app_parent" 2>/dev/null)" || die "application parent does not exist"
app_path="$app_parent_real/$app_name"
[[ -d "$app_path" && ! -L "$app_path" ]] || die "application must be a real directory"
[[ "$(/usr/bin/stat -f '%Lp' "$app_path")" == 755 ]] || die "application root mode must be 0755"

LIPO_EXECUTABLE="${VERIFY_APP_LIPO_EXECUTABLE:-/usr/bin/lipo}"
FILE_EXECUTABLE="${VERIFY_APP_FILE_EXECUTABLE:-/usr/bin/file}"
CODESIGN_EXECUTABLE="${VERIFY_APP_CODESIGN_EXECUTABLE:-/usr/bin/codesign}"
[[ -x "$LIPO_EXECUTABLE" ]] || die "lipo is required"
[[ -x "$FILE_EXECUTABLE" ]] || die "file is required"
[[ -x "$CODESIGN_EXECUTABLE" ]] || die "codesign is required"

validate_bundle_symlinks "$app_path"
info_plist="$app_path/Contents/Info.plist"
assert_real_file "$info_plist" "application Info.plist"
/usr/bin/plutil -lint "$info_plist" >/dev/null
assert_plist_value "$info_plist" CFBundleExecutable "$APP_NAME" "invalid CFBundleExecutable"
assert_plist_value "$info_plist" CFBundleIdentifier "$BUNDLE_ID" "invalid CFBundleIdentifier"
assert_plist_value "$info_plist" CFBundlePackageType APPL "invalid CFBundlePackageType"
assert_plist_value "$info_plist" CFBundleShortVersionString "$MARKETING_VERSION" \
  "CFBundleShortVersionString does not match version.env"
assert_plist_value "$info_plist" CFBundleVersion "$BUILD_NUMBER" \
  "CFBundleVersion does not match version.env"
assert_plist_value "$info_plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION" \
  "LSMinimumSystemVersion does not match release policy"

if [[ "$updates_enabled" == true ]]; then
  assert_plist_value "$info_plist" SUFeedURL "$PRODUCTION_FEED_URL" "invalid SUFeedURL"
  assert_plist_value "$info_plist" SUPublicEDKey "$SPARKLE_PUBLIC_ED_KEY" "invalid SUPublicEDKey"
  for boolean_key in SUEnableAutomaticChecks SUAutomaticallyUpdate \
    SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
    assert_plist_value "$info_plist" "$boolean_key" true "$boolean_key must equal true"
  done
else
  assert_plist_value "$info_plist" CodexRadarUpdatesEnabled false \
    "CodexRadarUpdatesEnabled must equal false"
  for absent_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks \
    SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
    assert_plist_key_absent "$info_plist" "$absent_key"
  done
fi

assert_real_file "$app_path/Contents/Resources/en.lproj/Localizable.strings" \
  "English localization"
assert_real_file "$app_path/Contents/Resources/zh-hans.lproj/Localizable.strings" \
  "Simplified Chinese localization"

framework_path="$app_path/Contents/Frameworks/Sparkle.framework"
version_root="$framework_path/Versions/B"
validate_sparkle_layout "$app_path" "$framework_path" "$version_root"
expected_machos=(
  "$app_path/Contents/MacOS/$APP_NAME"
  "$version_root/Sparkle"
  "$version_root/Autoupdate"
  "$version_root/Updater.app/Contents/MacOS/Updater"
  "$version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer"
)
for executable_path in "${expected_machos[@]}"; do
  assert_macho_executable "$executable_path"
done

macho_count=0
while IFS= read -r -d '' candidate; do
  file_description="$("$FILE_EXECUTABLE" -b "$candidate")" ||
    die "unable to inspect bundle file: $candidate"
  case "$file_description" in
    Mach-O*)
      expected=false
      for expected_path in "${expected_machos[@]}"; do
        if [[ "$candidate" == "$expected_path" ]]; then
          expected=true
          break
        fi
      done
      [[ "$expected" == true ]] || die "unexpected Mach-O in application: $candidate"
      if [[ "$updates_enabled" == true || "$candidate" != "$app_path/Contents/MacOS/$APP_NAME" ]]; then
        assert_exact_architectures "$candidate" arm64 x86_64
      else
        assert_exact_architectures "$candidate" "${EXPECTED_ARCHITECTURES[@]}"
      fi
      macho_count=$((macho_count + 1))
      ;;
  esac
done < <(/usr/bin/find -s "$app_path" -type f -print0)
[[ "$macho_count" -eq "${#expected_machos[@]}" ]] ||
  die "application does not contain the exact expected Mach-O set"

"$CODESIGN_EXECUTABLE" --verify --deep --strict --verbose=2 "$app_path"
known_code_objects=(
  "$version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$version_root/XPCServices/Downloader.xpc"
  "$version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "$version_root/XPCServices/Installer.xpc"
  "$version_root/Autoupdate"
  "$version_root/Updater.app/Contents/MacOS/Updater"
  "$version_root/Updater.app"
  "$version_root/Sparkle"
  "$framework_path"
  "$app_path/Contents/MacOS/$APP_NAME"
  "$app_path"
)
outer_authorities=""
outer_team_identifier=""
if [[ "$signing_mode" == developer-id ]]; then
  outer_signature_details="$("$CODESIGN_EXECUTABLE" -d --verbose=4 "$app_path" 2>&1)" ||
    die "unable to inspect application signature"
  outer_authorities="$(printf '%s\n' "$outer_signature_details" | \
    /usr/bin/awk '/^Authority=/{print}')"
  outer_team_identifier="$(printf '%s\n' "$outer_signature_details" | \
    /usr/bin/awk -F= '$1 == "TeamIdentifier" {print substr($0, index($0, "=") + 1); exit}')"
  [[ -n "$outer_authorities" && -n "$outer_team_identifier" && \
    "$outer_team_identifier" != "not set" ]] ||
    die "application does not have a usable developer-id identity"
fi
for code_object in "${known_code_objects[@]}"; do
  signature_details="$("$CODESIGN_EXECUTABLE" -d --verbose=4 "$code_object" 2>&1)" ||
    die "unable to inspect code object signature: $code_object"
  signature_kind="$(printf '%s\n' "$signature_details" | \
    /usr/bin/awk -F= '$1 == "Signature" {print substr($0, index($0, "=") + 1); exit}')"
  if [[ "$signing_mode" == adhoc ]]; then
    [[ "$signature_kind" == adhoc ]] ||
      die "code object is not signed with an ad-hoc identity: $code_object"
  else
    code_authorities="$(printf '%s\n' "$signature_details" | \
      /usr/bin/awk '/^Authority=/{print}')"
    code_team_identifier="$(printf '%s\n' "$signature_details" | \
      /usr/bin/awk -F= '$1 == "TeamIdentifier" {print substr($0, index($0, "=") + 1); exit}')"
    [[ "$signature_kind" != adhoc && "$code_authorities" == "$outer_authorities" && \
      "$code_team_identifier" == "$outer_team_identifier" ]] ||
      die "developer-id identity mismatch for code object: $code_object"
  fi
done
if [[ "$signing_mode" == developer-id ]]; then
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
  /usr/bin/xcrun stapler validate "$app_path"
fi

printf 'verified %s Mach-O files with signing mode %s\n' "$macho_count" "$signing_mode"
