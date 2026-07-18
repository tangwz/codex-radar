#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

APP_BUNDLE="${1:-}"
SIGNING_MODE="${SIGNING_MODE:-}"

[[ -d "$APP_BUNDLE" ]] || codex_radar_die "Missing app bundle: $APP_BUNDLE"

case "$SIGNING_MODE" in
  adhoc)
    /usr/bin/codesign --force --sign - "$APP_BUNDLE"
    ;;
  developer-id)
    [[ -n "${MACOS_SIGNING_IDENTITY:-}" ]] \
      || codex_radar_die "Missing MACOS_SIGNING_IDENTITY"
    /usr/bin/codesign \
      --force \
      --timestamp \
      --options runtime \
      --sign "$MACOS_SIGNING_IDENTITY" \
      "$APP_BUNDLE"
    ;;
  *)
    codex_radar_die "Unsupported SIGNING_MODE: $SIGNING_MODE"
    ;;
esac
