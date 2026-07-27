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

tag_repository="$fixture_dir/tag-repository"
git init -q "$tag_repository"
git -C "$tag_repository" config user.name "Release Test"
git -C "$tag_repository" config user.email "release-test@example.com"
printf 'MARKETING_VERSION=0.1.0\nBUILD_NUMBER=1\n' >"$tag_repository/version.env"
git -C "$tag_repository" add version.env
git -C "$tag_repository" commit -qm "release: add first identity"
git -C "$tag_repository" tag v0.1.0
printf 'MARKETING_VERSION=0.2.0\nBUILD_NUMBER=2\n' >"$tag_repository/version.env"
git -C "$tag_repository" add version.env
git -C "$tag_repository" commit -qm "release: add second identity"
git -C "$tag_repository" tag v0.2.0
git -C "$tag_repository" tag vtest

printf 'MARKETING_VERSION=0.3.0\nBUILD_NUMBER=3\n' >"$fixture_dir/higher.env"
load_version_config "$fixture_dir/higher.env"
validate_release_identity_against_tags "v0.3.0" "$tag_repository"
[[ "$MARKETING_VERSION" == "0.3.0" ]]
[[ "$BUILD_NUMBER" == "3" ]]

load_version_config "$fixture_dir/valid.env"
validate_release_identity_against_tags "v0.2.0" "$tag_repository"

printf 'MARKETING_VERSION=0.1.5\nBUILD_NUMBER=3\n' >"$fixture_dir/lower-version.env"
load_version_config "$fixture_dir/lower-version.env"
if validate_release_identity_against_tags "v0.1.5" "$tag_repository"; then
  echo "release accepted a lower App Version" >&2
  exit 1
fi

printf 'MARKETING_VERSION=0.3.0\nBUILD_NUMBER=2\n' >"$fixture_dir/reused-build.env"
load_version_config "$fixture_dir/reused-build.env"
if validate_release_identity_against_tags "v0.3.0" "$tag_repository"; then
  echo "release accepted a reused build number" >&2
  exit 1
fi

semantic_version_is_greater "100000000000000000000.0.0" "99999999999999999999.999.999"
