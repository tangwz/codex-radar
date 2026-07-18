#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

APP_BUNDLE="${1:-}"
shift || true
EXPECTED_ARCHES=("$@")
SIGNING_MODE="${SIGNING_MODE:-}"

[[ -d "$APP_BUNDLE" && ${#EXPECTED_ARCHES[@]} -gt 0 ]] \
  || codex_radar_die "Usage: verify_app.sh APP EXPECTED_ARCH..."

load_version "$ROOT_DIR/version.env"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"

/usr/bin/plutil -lint "$INFO_PLIST"

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$INFO_PLIST"
}

[[ "$(plist_value CFBundleShortVersionString)" == "$MARKETING_VERSION" ]] \
  || codex_radar_die "Unexpected marketing version"
[[ "$(plist_value CFBundleVersion)" == "$BUILD_NUMBER" ]] \
  || codex_radar_die "Unexpected build number"
[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] \
  || codex_radar_die "Unexpected bundle identifier"
[[ "$(plist_value CFBundleName)" == "$APP_NAME" ]] \
  || codex_radar_die "Unexpected bundle name"
[[ "$(plist_value LSMinimumSystemVersion)" == "$MIN_SYSTEM_VERSION" ]] \
  || codex_radar_die "Unexpected minimum system version"

actual_arches="$(
  /usr/bin/lipo -archs "$APP_BINARY" \
    | tr ' ' '\n' \
    | LC_ALL=C sort \
    | paste -sd ' ' -
)"
expected_arches="$(
  printf '%s\n' "${EXPECTED_ARCHES[@]}" \
    | LC_ALL=C sort \
    | paste -sd ' ' -
)"
[[ "$actual_arches" == "$expected_arches" ]] \
  || codex_radar_die "Expected architectures '$expected_arches', found '$actual_arches'"

[[ -f "$APP_RESOURCES/AppIcon.icns" ]] || codex_radar_die "Missing AppIcon.icns"
[[ -f "$APP_RESOURCES/MenuBarIcon.png" ]] || codex_radar_die "Missing MenuBarIcon.png"
[[ -d "$APP_RESOURCES/en.lproj" ]] || codex_radar_die "Missing en.lproj"
[[ -d "$APP_RESOURCES/zh-Hans.lproj" ]] || codex_radar_die "Missing zh-Hans.lproj"
[[ -d "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME" ]] \
  || codex_radar_die "Missing SwiftPM resource bundle"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  /usr/sbin/spctl --assess --type execute --verbose "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
elif [[ "$SIGNING_MODE" != "adhoc" ]]; then
  codex_radar_die "Unsupported SIGNING_MODE: $SIGNING_MODE"
fi

echo "Verified $APP_BUNDLE"
