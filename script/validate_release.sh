#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TAG="${1:-}"
COMMIT="${2:-}"
MAIN_REF="${3:-}"

load_version "$ROOT_DIR/version.env"

if [[ -n "$TAG" ]]; then
  validate_release_tag "$TAG"
fi

if [[ -n "$COMMIT" || -n "$MAIN_REF" ]]; then
  [[ -n "$COMMIT" && -n "$MAIN_REF" ]] \
    || codex_radar_die "Commit and main ref must be provided together"
  assert_commit_on_main "$ROOT_DIR" "$COMMIT" "$MAIN_REF"
fi

printf 'Validated CodexRadar %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
