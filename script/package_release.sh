#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

OUTPUT_DIR="${1:-$ROOT_DIR/dist/release}"
SIGNING_MODE="${SIGNING_MODE:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-}"

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR" ;;
esac

[[ "$OUTPUT_DIR" == "$ROOT_DIR/"* ]] \
  || codex_radar_die "Release output must remain inside the repository"

load_version "$ROOT_DIR/version.env"
validate_release_channel "$SIGNING_MODE" "$RELEASE_PRERELEASE"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  require_developer_id_environment
fi

mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/tmp"
TEMP_DIR="$(mktemp -d "$ROOT_DIR/tmp/package-release.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ASSET="$OUTPUT_DIR/$(release_asset_name)"
CHECKSUM="$OUTPUT_DIR/$(release_checksum_name)"

notarize_app() {
  local app_bundle="$1"
  local api_key_path="$TEMP_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  local submission_zip="$TEMP_DIR/${APP_NAME}-notarization.zip"

  (
    umask 077
    printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" > "$api_key_path"
  )
  /usr/bin/ditto --norsrc -c -k --keepParent "$app_bundle" "$submission_zip"
  /usr/bin/xcrun notarytool submit "$submission_zip" \
    --key "$api_key_path" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  /usr/bin/xcrun stapler staple "$app_bundle"
}

"$ROOT_DIR/script/package_app.sh" \
  release \
  "$APP_BUNDLE" \
  arm64 \
  x86_64
SIGNING_MODE="$SIGNING_MODE" "$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  notarize_app "$APP_BUNDLE"
fi

SIGNING_MODE="$SIGNING_MODE" \
  "$ROOT_DIR/script/verify_app.sh" \
  "$APP_BUNDLE" \
  arm64 \
  x86_64

rm -f "$ASSET" "$CHECKSUM"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ASSET"

EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ASSET" "$EXTRACT_DIR"
ENTRY_COUNT="$(
  find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print \
    | wc -l \
    | tr -d '[:space:]'
)"
[[ "$ENTRY_COUNT" == "1" && -d "$EXTRACT_DIR/$APP_NAME.app" ]] \
  || codex_radar_die "Release ZIP must contain exactly one top-level app"

SIGNING_MODE="$SIGNING_MODE" \
  "$ROOT_DIR/script/verify_app.sh" \
  "$EXTRACT_DIR/$APP_NAME.app" \
  arm64 \
  x86_64

(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ASSET")" > "$(basename "$CHECKSUM")"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

printf 'Created %s\n' "$ASSET"
printf 'Created %s\n' "$CHECKSUM"
