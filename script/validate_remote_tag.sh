#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/lib/release_common.sh"

[[ $# -ge 2 && $# -le 3 ]] \
  || {
    codex_radar_die "Usage: $0 TAG EXPECTED_COMMIT [REMOTE]"
    exit 1
  }

TAG="$1"
EXPECTED_COMMIT="$2"
REMOTE="${3:-origin}"

load_version "$ROOT_DIR/version.env"
assert_remote_tag_commit "$ROOT_DIR" "$TAG" "$EXPECTED_COMMIT" "$REMOTE"
printf 'Verified remote tag %s at %s on %s\n' \
  "$TAG" \
  "$EXPECTED_COMMIT" \
  "$REMOTE"
