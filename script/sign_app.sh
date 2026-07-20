#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_SPARKLE_BUILD="2059"
EXPECTED_SPARKLE_MIN_SYSTEM_VERSION="10.13"

usage() {
  echo "usage: $0 --app PATH --signing-mode adhoc|developer-id" >&2
  return 2
}

assert_real_directory() {
  local path="$1" description="$2"

  [[ -d "$path" && ! -L "$path" ]] || die "$description must be a real directory" || return 1
}

assert_plist_value() {
  local plist_path="$1" key="$2" expected="$3" failure_message="$4" actual

  actual="$(/usr/bin/plutil -extract "$key" raw "$plist_path" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || die "$failure_message" || return 1
}

assert_symlink_target() {
  local link_path="$1" expected_target="$2" description="$3"

  [[ -L "$link_path" ]] || die "$description must be a symlink" || return 1
  [[ "$(/usr/bin/readlink "$link_path")" == "$expected_target" ]] ||
    die "$description has an unexpected target" || return 1
}

assert_macho_executable() {
  local executable_path="$1" file_description

  [[ -f "$executable_path" && ! -L "$executable_path" && -x "$executable_path" ]] ||
    die "missing expected executable: $executable_path" || return 1
  file_description="$(/usr/bin/file -b "$executable_path")" ||
    die "unable to inspect expected executable: $executable_path" || return 1
  case "$file_description" in
    Mach-O*) ;;
    *) die "expected executable is not Mach-O: $executable_path" || return 1 ;;
  esac
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

validate_exact_macho_set() {
  local app_path="$1" candidate file_description expected_path found expected_count
  shift
  local expected_paths=("$@")

  expected_count=0
  while IFS= read -r -d '' candidate; do
    file_description="$(/usr/bin/file -b "$candidate")" ||
      die "unable to inspect bundle file: $candidate" || return 1
    case "$file_description" in
      Mach-O*)
        found=false
        for expected_path in "${expected_paths[@]}"; do
          if [[ "$candidate" == "$expected_path" ]]; then
            found=true
            break
          fi
        done
        [[ "$found" == true ]] || die "unexpected Mach-O in application: $candidate" || return 1
        expected_count=$((expected_count + 1))
        ;;
    esac
  done < <(/usr/bin/find -s "$app_path" -type f -print0)

  [[ "$expected_count" -eq "${#expected_paths[@]}" ]] ||
    die "application does not contain the exact expected Mach-O set" || return 1
}

validate_sparkle_layout() {
  local app_path="$1" framework_path="$2" version_root="$3"
  local xpc_root="$version_root/XPCServices" entry_path entry_name entry_count
  local xpc_path plist_path executable_name expected_bundle_id expected_path
  local updater_path="$version_root/Updater.app"

  assert_real_directory "$app_path/Contents" "application Contents"
  assert_real_directory "$app_path/Contents/MacOS" "application MacOS"
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

  assert_plist_value "$version_root/Resources/Info.plist" \
    CFBundleIdentifier org.sparkle-project.Sparkle \
    "invalid Sparkle.framework bundle identifier"
  assert_plist_value "$version_root/Resources/Info.plist" \
    CFBundleShortVersionString "$EXPECTED_SPARKLE_VERSION" \
    "embedded Sparkle.framework must equal $EXPECTED_SPARKLE_VERSION"
  assert_plist_value "$version_root/Resources/Info.plist" \
    CFBundleVersion "$EXPECTED_SPARKLE_BUILD" "invalid Sparkle.framework build"
  assert_plist_value "$version_root/Resources/Info.plist" \
    CFBundlePackageType FMWK "invalid Sparkle.framework package type"
  assert_plist_value "$version_root/Resources/Info.plist" \
    LSMinimumSystemVersion "$EXPECTED_SPARKLE_MIN_SYSTEM_VERSION" \
    "invalid Sparkle.framework minimum system version"
  assert_plist_value "$version_root/Resources/Info.plist" \
    CFBundleExecutable Sparkle "invalid Sparkle.framework executable declaration"
  assert_plist_value "$updater_path/Contents/Info.plist" \
    CFBundleIdentifier org.sparkle-project.Sparkle.Updater \
    "invalid Sparkle Updater.app bundle identifier"
  assert_plist_value "$updater_path/Contents/Info.plist" \
    CFBundleShortVersionString "$EXPECTED_SPARKLE_VERSION" \
    "Sparkle Updater.app must equal $EXPECTED_SPARKLE_VERSION"
  assert_plist_value "$updater_path/Contents/Info.plist" \
    CFBundleVersion "$EXPECTED_SPARKLE_BUILD" "invalid Sparkle Updater.app build"
  assert_plist_value "$updater_path/Contents/Info.plist" \
    CFBundlePackageType APPL "invalid Sparkle Updater.app package type"
  assert_plist_value "$updater_path/Contents/Info.plist" \
    LSMinimumSystemVersion "$EXPECTED_SPARKLE_MIN_SYSTEM_VERSION" \
    "invalid Sparkle Updater.app minimum system version"
  assert_plist_value "$updater_path/Contents/Info.plist" \
    CFBundleExecutable Updater "invalid Sparkle Updater.app executable declaration"

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

  for entry_name in Downloader.xpc Installer.xpc; do
    xpc_path="$xpc_root/$entry_name"
    [[ -d "$xpc_path" && ! -L "$xpc_path" ]] ||
      die "missing Sparkle XPC service: $entry_name" || return 1
    plist_path="$xpc_path/Contents/Info.plist"
    executable_name="${entry_name%.xpc}"
    case "$entry_name" in
      Downloader.xpc) expected_bundle_id=org.sparkle-project.DownloaderService ;;
      Installer.xpc) expected_bundle_id=org.sparkle-project.InstallerLauncher ;;
    esac
    assert_plist_value "$plist_path" CFBundleShortVersionString \
      "$EXPECTED_SPARKLE_VERSION" "Sparkle XPC service version mismatch: $entry_name"
    assert_plist_value "$plist_path" CFBundleVersion "$EXPECTED_SPARKLE_BUILD" \
      "Sparkle XPC service build mismatch: $entry_name"
    assert_plist_value "$plist_path" CFBundlePackageType 'XPC!' \
      "invalid Sparkle XPC package type: $entry_name"
    assert_plist_value "$plist_path" LSMinimumSystemVersion \
      "$EXPECTED_SPARKLE_MIN_SYSTEM_VERSION" \
      "invalid Sparkle XPC minimum system version: $entry_name"
    assert_plist_value "$plist_path" CFBundleExecutable "$executable_name" \
      "invalid Sparkle XPC executable declaration: $entry_name"
    assert_plist_value "$plist_path" CFBundleIdentifier "$expected_bundle_id" \
      "invalid Sparkle XPC bundle identifier: $entry_name"
  done

  expected_path="$app_path/Contents/MacOS/$APP_NAME"
  assert_macho_executable "$expected_path"
  assert_macho_executable "$version_root/Sparkle"
  assert_macho_executable "$version_root/Autoupdate"
  assert_macho_executable "$updater_path/Contents/MacOS/Updater"
  assert_macho_executable "$xpc_root/Downloader.xpc/Contents/MacOS/Downloader"
  assert_macho_executable "$xpc_root/Installer.xpc/Contents/MacOS/Installer"
  validate_exact_macho_set "$app_path" \
    "$expected_path" \
    "$version_root/Sparkle" \
    "$version_root/Autoupdate" \
    "$updater_path/Contents/MacOS/Updater" \
    "$xpc_root/Downloader.xpc/Contents/MacOS/Downloader" \
    "$xpc_root/Installer.xpc/Contents/MacOS/Installer"
}

app_argument=""
signing_mode=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app)
      [[ -z "$app_argument" && "$#" -ge 2 ]] || usage
      app_argument="$2"
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
[[ -n "$app_argument" && -n "$signing_mode" ]] || usage

app_parent="$(/usr/bin/dirname "$app_argument")"
app_name="$(/usr/bin/basename "$app_argument")"
[[ "$app_name" == "$APP_NAME.app" ]] || die "application must be named $APP_NAME.app"
app_parent_real="$(/bin/realpath "$app_parent" 2>/dev/null)" || die "application parent does not exist"
app_path="$app_parent_real/$app_name"
[[ -d "$app_path" && ! -L "$app_path" ]] || die "application must be a real directory"

CODESIGN_EXECUTABLE="${SIGN_APP_CODESIGN_EXECUTABLE:-/usr/bin/codesign}"
[[ -x "$CODESIGN_EXECUTABLE" ]] || die "codesign is required"
case "$signing_mode" in
  adhoc)
    sign_target() {
      "$CODESIGN_EXECUTABLE" --force --sign - "$1"
    }
    ;;
  developer-id)
    [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] ||
      die "developer-id signing requires DEVELOPER_ID_APPLICATION"
    [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]] ||
      die "developer-id signing requires APP_STORE_CONNECT_API_KEY_PATH"
    [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" && ! -L "$APP_STORE_CONNECT_API_KEY_PATH" ]] ||
      die "developer-id signing requires a real App Store Connect API key file"
    [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] ||
      die "developer-id signing requires APP_STORE_CONNECT_KEY_ID"
    [[ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] ||
      die "developer-id signing requires APP_STORE_CONNECT_ISSUER_ID"
    sign_target() {
      "$CODESIGN_EXECUTABLE" --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" "$1"
    }
    ;;
  *) die "signing-mode must be adhoc or developer-id" ;;
esac

validate_bundle_symlinks "$app_path"
framework_path="$app_path/Contents/Frameworks/Sparkle.framework"
version_root="$framework_path/Versions/B"
validate_sparkle_layout "$app_path" "$framework_path" "$version_root"

for xpc_name in Downloader Installer; do
  xpc_path="$version_root/XPCServices/$xpc_name.xpc"
  sign_target "$xpc_path/Contents/MacOS/$xpc_name"
  sign_target "$xpc_path"
done
sign_target "$version_root/Autoupdate"
sign_target "$version_root/Updater.app"
sign_target "$framework_path"
sign_target "$app_path/Contents/MacOS/$APP_NAME"
sign_target "$app_path"
