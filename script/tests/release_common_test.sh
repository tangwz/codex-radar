#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-release-common.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

expect_failure() {
  local name="$1"
  shift
  if ("$@"); then
    echo "Expected failure: $name" >&2
    exit 1
  fi
}

write_version() {
  local path="$1"
  local version="$2"
  local build="$3"
  {
    printf 'MARKETING_VERSION=%s\n' "$version"
    printf 'BUILD_NUMBER=%s\n' "$build"
  } > "$path"
}

GOOD_VERSION_FILE="$TEST_DIR/version.env"
write_version "$GOOD_VERSION_FILE" "0.1.0" "1"
load_version "$GOOD_VERSION_FILE"
[[ "$MARKETING_VERSION" == "0.1.0" ]]
[[ "$BUILD_NUMBER" == "1" ]]
validate_release_tag "v0.1.0"
[[ "$(release_asset_name)" == "CodexRadar-v0.1.0-macos-universal.zip" ]]
[[ "$(release_checksum_name)" == "CodexRadar-v0.1.0-macos-universal.zip.sha256" ]]

BAD_VERSION_FILE="$TEST_DIR/bad-version.env"
write_version "$BAD_VERSION_FILE" "0.1" "1"
expect_failure "invalid semantic version" load_version "$BAD_VERSION_FILE"

BAD_BUILD_FILE="$TEST_DIR/bad-build.env"
write_version "$BAD_BUILD_FILE" "0.1.0" "0"
expect_failure "non-positive build number" load_version "$BAD_BUILD_FILE"

EXTRA_KEY_FILE="$TEST_DIR/extra-key.env"
{
  printf 'MARKETING_VERSION=0.1.0\n'
  printf 'BUILD_NUMBER=1\n'
  printf 'UNEXPECTED=value\n'
} > "$EXTRA_KEY_FILE"
expect_failure "unexpected version key" load_version "$EXTRA_KEY_FILE"

load_version "$GOOD_VERSION_FILE"
expect_failure "tag mismatch" validate_release_tag "v0.1.1"
expect_failure "tag prefix missing" validate_release_tag "0.1.0"
expect_failure "incomplete semantic version" validate_release_tag "v0.1"
validate_release_channel "adhoc" "true"
expect_failure "adhoc stable release" validate_release_channel "adhoc" "false"
expect_failure "unknown signing mode" validate_release_channel "automatic" "true"

missing_developer_credential() {
  local missing="$1"
  export MACOS_SIGNING_IDENTITY="identity"
  export APP_STORE_CONNECT_API_KEY_P8="key"
  export APP_STORE_CONNECT_KEY_ID="key-id"
  export APP_STORE_CONNECT_ISSUER_ID="issuer-id"
  unset "$missing"
  require_developer_id_environment
}
for missing in \
  MACOS_SIGNING_IDENTITY \
  APP_STORE_CONNECT_API_KEY_P8 \
  APP_STORE_CONNECT_KEY_ID \
  APP_STORE_CONNECT_ISSUER_ID; do
  expect_failure \
    "missing $missing" \
    missing_developer_credential \
    "$missing"
done

REPO_DIR="$TEST_DIR/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.name "Release Test"
git -C "$REPO_DIR" config user.email "release-test@example.com"
printf 'main\n' > "$REPO_DIR/state.txt"
git -C "$REPO_DIR" add state.txt
git -C "$REPO_DIR" commit -q -m "main"
MAIN_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$MAIN_COMMIT"
assert_commit_on_main "$REPO_DIR" "$MAIN_COMMIT" "refs/remotes/origin/main"

git -C "$REPO_DIR" checkout -q -b release-test
printf 'branch\n' > "$REPO_DIR/state.txt"
git -C "$REPO_DIR" commit -q -am "branch"
BRANCH_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
expect_failure \
  "commit outside main" \
  assert_commit_on_main "$REPO_DIR" "$BRANCH_COMMIT" "refs/remotes/origin/main"

echo "release_common_test: PASS"
