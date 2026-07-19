#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
printf 'MARKETING_VERSION=0.2.0\nBUILD_NUMBER=2\n' >"$fixture_dir/valid.env"
load_version_config "$fixture_dir/valid.env"
[[ "$MARKETING_VERSION" == "0.2.0" ]]
[[ "$BUILD_NUMBER" == "2" ]]
validate_release_tag "v0.2.0"

printf 'MARKETING_VERSION=0.2\nBUILD_NUMBER=2\n' >"$fixture_dir/bad-version.env"
if (load_version_config "$fixture_dir/bad-version.env"); then
  echo "invalid marketing version was accepted" >&2
  exit 1
fi
