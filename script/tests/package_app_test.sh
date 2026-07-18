#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$ROOT_DIR/tmp/package-app-test"
ASSEMBLED_APP="$TEST_DIR/CodexRadar.app"
APP_BUNDLE="$TEST_DIR/relocated/CodexRadar.app"
ESCAPE_APP="$TEST_DIR/../package-app-escape/CodexRadar.app"
RESOURCE_BUNDLE_NAME="CodexRadar_CodexRadar.bundle"
RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE_NAME"
BUNDLE_CHECK_SOURCE="$TEST_DIR/BundleCheck.swift"
BUNDLE_CHECK_BINARY="$APP_BUNDLE/Contents/MacOS/BundleCheck"
ARCH="$(uname -m)"

rm -rf "$TEST_DIR" "$ROOT_DIR/tmp/package-app-escape"
trap 'rm -rf "$TEST_DIR" "$ROOT_DIR/tmp/package-app-escape"' EXIT

if "$ROOT_DIR/script/package_app.sh" debug "$ESCAPE_APP" "$ARCH"; then
  echo "Expected packaging to reject a path that traverses the repository" >&2
  exit 1
fi

"$ROOT_DIR/script/package_app.sh" debug "$ASSEMBLED_APP" "$ARCH"
mkdir -p "$(dirname "$APP_BUNDLE")"
mv "$ASSEMBLED_APP" "$APP_BUNDLE"

[[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$APP_BUNDLE/Contents/Info.plist")" == "CodexRadar" ]]
[[ -d "$RESOURCE_BUNDLE" ]]

cat > "$BUNDLE_CHECK_SOURCE" <<'SWIFT'
import Foundation

guard let resourceURL = Bundle.main.url(
  forResource: "MenuBarIcon",
  withExtension: "png"
) else {
  fatalError("Unable to load MenuBarIcon from packaged Bundle.main")
}

print(resourceURL.path)
SWIFT

/usr/bin/swiftc "$BUNDLE_CHECK_SOURCE" -o "$BUNDLE_CHECK_BINARY"
"$BUNDLE_CHECK_BINARY"
rm -f "$BUNDLE_CHECK_BINARY"

SIGNING_MODE=adhoc "$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE"
SIGNING_MODE=adhoc "$ROOT_DIR/script/verify_app.sh" "$APP_BUNDLE" "$ARCH"

OTHER_ARCH="arm64"
if [[ "$ARCH" == "arm64" ]]; then
  OTHER_ARCH="x86_64"
fi
if SIGNING_MODE=adhoc \
  "$ROOT_DIR/script/verify_app.sh" \
  "$APP_BUNDLE" \
  "$ARCH" \
  "$OTHER_ARCH"; then
  echo "Expected verification to reject a missing architecture" >&2
  exit 1
fi

[[ -x "$APP_BUNDLE/Contents/MacOS/CodexRadar" ]]
[[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]
[[ -f "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png" ]]
[[ -d "$APP_BUNDLE/Contents/Resources/en.lproj" ]]
[[ -d "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj" ]]
[[ -d "$RESOURCE_BUNDLE" ]]

echo "package_app_test: PASS"
