#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

OUTPUT_DIR="$ROOT_DIR/tmp/package-release-test"
EXTRACT_DIR="$ROOT_DIR/tmp/package-release-extract"
rm -rf "$OUTPUT_DIR" "$EXTRACT_DIR"
trap 'rm -rf "$OUTPUT_DIR" "$EXTRACT_DIR"' EXIT

if (
  unset MACOS_SIGNING_IDENTITY
  unset APP_STORE_CONNECT_API_KEY_P8
  unset APP_STORE_CONNECT_KEY_ID
  unset APP_STORE_CONNECT_ISSUER_ID
  SIGNING_MODE=developer-id \
    RELEASE_PRERELEASE=false \
    "$ROOT_DIR/script/package_release.sh" "$OUTPUT_DIR"
); then
  echo "Expected developer-id packaging to reject missing credentials" >&2
  exit 1
fi

SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" "$OUTPUT_DIR"

load_version "$ROOT_DIR/version.env"
ASSET="$OUTPUT_DIR/$(release_asset_name)"
CHECKSUM="$OUTPUT_DIR/$(release_checksum_name)"
[[ -f "$ASSET" ]]
[[ -f "$CHECKSUM" ]]

(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ASSET" "$EXTRACT_DIR"
[[ "$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" == "1" ]]
SIGNING_MODE=adhoc \
  "$ROOT_DIR/script/verify_app.sh" \
  "$EXTRACT_DIR/CodexRadar.app" \
  arm64 \
  x86_64

echo "package_release_test: PASS"
