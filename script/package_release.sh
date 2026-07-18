#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/lib/release_common.sh"

OUTPUT_DIR_INPUT="${1:-$ROOT_DIR/dist/release}"
SIGNING_MODE="${SIGNING_MODE:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-}"

normalize_output_dir() {
  local requested="$1"
  local relative_output=""
  local candidate="$ROOT_DIR"
  local component=""
  local existing_parent=""
  local physical_parent=""
  local -a output_components=()

  requested="${requested%/}"
  case "$requested" in
    /*)
      [[ "$requested" == "$ROOT_DIR/"* ]] \
        || {
          codex_radar_die "Release output must remain inside the repository"
          return 1
        }
      relative_output="${requested#"$ROOT_DIR"/}"
      ;;
    *)
      relative_output="$requested"
      ;;
  esac

  [[ -n "$relative_output" && "$relative_output" != *//* ]] \
    || {
      codex_radar_die "Release output path contains invalid components"
      return 1
    }

  IFS='/' read -r -a output_components <<< "$relative_output"
  for component in "${output_components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || {
        codex_radar_die "Release output path contains invalid components"
        return 1
      }
    candidate="$candidate/$component"
    [[ ! -L "$candidate" ]] \
      || {
        codex_radar_die "Release output parent must not contain symbolic links"
        return 1
      }
    [[ ! -e "$candidate" || -d "$candidate" ]] \
      || {
        codex_radar_die "Release output parent contains a non-directory path"
        return 1
      }
  done

  existing_parent="$candidate"
  while [[ ! -d "$existing_parent" ]]; do
    existing_parent="$(dirname "$existing_parent")"
  done
  physical_parent="$(cd "$existing_parent" && pwd -P)"
  [[ "$physical_parent" == "$ROOT_DIR" || "$physical_parent" == "$ROOT_DIR/"* ]] \
    || {
      codex_radar_die "Release output must remain inside the repository"
      return 1
    }

  printf '%s\n' "$candidate"
}

load_version "$ROOT_DIR/version.env"
validate_release_channel "$SIGNING_MODE" "$RELEASE_PRERELEASE"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  require_developer_id_environment
fi

OUTPUT_DIR="$(normalize_output_dir "$OUTPUT_DIR_INPUT")"
mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/tmp"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
[[ "$OUTPUT_DIR" == "$ROOT_DIR/"* ]] \
  || codex_radar_die "Release output must remain inside the repository"

FINAL_ASSET="$OUTPUT_DIR/$(release_asset_name)"
FINAL_CHECKSUM="$OUTPUT_DIR/$(release_checksum_name)"
rm -f "$FINAL_ASSET" "$FINAL_CHECKSUM"

TEMP_DIR="$(mktemp -d "$ROOT_DIR/tmp/package-release.XXXXXX")"
PUBLISH_DIR=""
PUBLISH_SUCCEEDED=false
cleanup() {
  rm -rf "$TEMP_DIR"
  if [[ -n "$PUBLISH_DIR" ]]; then
    rm -rf "$PUBLISH_DIR"
  fi
  if [[ "$PUBLISH_SUCCEEDED" != "true" ]]; then
    rm -f "$FINAL_ASSET" "$FINAL_CHECKSUM"
  fi
}
trap cleanup EXIT

APP_BUNDLE="$TEMP_DIR/$APP_NAME.app"
ASSET="$TEMP_DIR/$(release_asset_name)"
CHECKSUM="$TEMP_DIR/$(release_checksum_name)"

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
  cd "$TEMP_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ASSET")" > "$(basename "$CHECKSUM")"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

PUBLISH_DIR="$(mktemp -d "$OUTPUT_DIR/.package-release.XXXXXX")"
PUBLISH_ASSET="$PUBLISH_DIR/$(basename "$ASSET")"
PUBLISH_CHECKSUM="$PUBLISH_DIR/$(basename "$CHECKSUM")"
/bin/cp "$ASSET" "$PUBLISH_ASSET"
/bin/cp "$CHECKSUM" "$PUBLISH_CHECKSUM"
/bin/mv "$PUBLISH_CHECKSUM" "$FINAL_CHECKSUM"
/bin/mv "$PUBLISH_ASSET" "$FINAL_ASSET"
rmdir "$PUBLISH_DIR"
PUBLISH_DIR=""
PUBLISH_SUCCEEDED=true

printf 'Created %s\n' "$FINAL_ASSET"
printf 'Created %s\n' "$FINAL_CHECKSUM"
