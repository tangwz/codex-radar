#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TAG="${1:-}"
ASSET="${2:-}"
CHECKSUM="${3:-}"
SIGNING_MODE="${SIGNING_MODE:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-}"
GH_BIN="${GH_BIN:-gh}"
NOTES_FILE="$ROOT_DIR/.github/release-notes-adhoc.md"

load_version "$ROOT_DIR/version.env"
validate_release_tag "$TAG"
validate_release_channel "$SIGNING_MODE" "$RELEASE_PRERELEASE"

[[ -f "$ASSET" ]] || codex_radar_die "Missing release asset: $ASSET"
[[ -f "$CHECKSUM" ]] || codex_radar_die "Missing checksum: $CHECKSUM"
[[ "$(basename "$ASSET")" == "$(release_asset_name)" ]] \
  || codex_radar_die "Unexpected release asset name"
[[ "$(basename "$CHECKSUM")" == "$(release_checksum_name)" ]] \
  || codex_radar_die "Unexpected checksum name"
[[ "$(dirname "$ASSET")" == "$(dirname "$CHECKSUM")" ]] \
  || codex_radar_die "Release asset and checksum must share a directory"
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  [[ -f "$NOTES_FILE" ]] || codex_radar_die "Missing release notes preamble"
fi

CHECKSUM_RECORD_COUNT="$(/usr/bin/awk 'END { print NR }' "$CHECKSUM")"
[[ "$CHECKSUM_RECORD_COUNT" == "1" ]] \
  || codex_radar_die "Checksum file must contain exactly one record"
CHECKSUM_HASH=""
CHECKSUM_TARGET=""
CHECKSUM_EXTRA=""
read -r CHECKSUM_HASH CHECKSUM_TARGET CHECKSUM_EXTRA < "$CHECKSUM" \
  || codex_radar_die "Invalid checksum file"
[[ "$CHECKSUM_HASH" =~ ^[0-9a-fA-F]{64}$ ]] \
  || codex_radar_die "Invalid checksum digest"
[[ "$CHECKSUM_TARGET" == "$(basename "$ASSET")" && -z "$CHECKSUM_EXTRA" ]] \
  || codex_radar_die "Checksum must reference the release asset"
(
  cd "$(dirname "$ASSET")"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

release_is_missing() {
  local error_message="$1"
  [[ "$error_message" == "release not found" ]]
}

RELEASE_STATE=""
if RELEASE_STATE="$(
  "$GH_BIN" release view "$TAG" --json isDraft --jq '.isDraft' 2>&1
)"; then
  case "$RELEASE_STATE" in
    true)
      if [[ "$SIGNING_MODE" == "adhoc" ]]; then
        DRAFT_BODY=""
        if ! DRAFT_BODY="$(
          "$GH_BIN" release view "$TAG" --json body --jq '.body'
        )"; then
          codex_radar_die "Unable to verify release notes for draft $TAG"
        fi
        NOTES_PREAMBLE="$(cat "$NOTES_FILE")"
        case "$DRAFT_BODY" in
          "$NOTES_PREAMBLE" | "$NOTES_PREAMBLE"$'\n'*)
            ;;
          *)
            codex_radar_die "Draft $TAG is missing the ad-hoc release warning"
            ;;
        esac
      fi
      ;;
    false)
      codex_radar_die "Release $TAG is already public and cannot be overwritten"
      ;;
    *)
      codex_radar_die "Unexpected release state for $TAG: $RELEASE_STATE"
      ;;
  esac
else
  if ! release_is_missing "$RELEASE_STATE"; then
    [[ -z "$RELEASE_STATE" ]] || printf '%s\n' "$RELEASE_STATE" >&2
    codex_radar_die "Unable to determine release state for $TAG"
  fi

  CREATE_ARGS=(
    release create "$TAG"
    --draft
    --verify-tag
    --title "Codex Radar $TAG"
    --generate-notes
  )
  if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    CREATE_ARGS+=(--notes "$(cat "$NOTES_FILE")")
  fi
  "$GH_BIN" "${CREATE_ARGS[@]}"
fi

"$GH_BIN" release upload "$TAG" "$ASSET" "$CHECKSUM" --clobber

if [[ "$RELEASE_PRERELEASE" == "true" ]]; then
  "$GH_BIN" release edit "$TAG" --draft=false --prerelease
else
  "$GH_BIN" release edit "$TAG" --draft=false --prerelease=false
fi
