#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$ROOT_DIR/tmp/package-app-test"
APP_BUNDLE="$TEST_DIR/CodexRadar.app"
ESCAPE_APP="$TEST_DIR/../package-app-escape/CodexRadar.app"
ARCH="$(uname -m)"

rm -rf "$TEST_DIR" "$ROOT_DIR/tmp/package-app-escape"
trap 'rm -rf "$TEST_DIR" "$ROOT_DIR/tmp/package-app-escape"' EXIT

if "$ROOT_DIR/script/package_app.sh" debug "$ESCAPE_APP" "$ARCH"; then
  echo "Expected packaging to reject a path that traverses the repository" >&2
  exit 1
fi

"$ROOT_DIR/script/package_app.sh" debug "$APP_BUNDLE" "$ARCH"
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
[[ -d "$APP_BUNDLE/Contents/Resources/CodexRadar_CodexRadar.bundle" ]]

echo "package_app_test: PASS"
