#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-remote-tag.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

REMOTE_DIR="$TEST_DIR/remote.git"
SOURCE_DIR="$TEST_DIR/source"
CLIENT_DIR="$TEST_DIR/client"

expect_failure() {
  local name="$1"
  shift
  if ("$@"); then
    echo "Expected failure: $name" >&2
    exit 1
  fi
}

assert_no_verification_refs() {
  [[ -z "$(git -C "$CLIENT_DIR" for-each-ref --format='%(refname)' \
    refs/codex-radar/remote-tag-validation/)" ]] \
    || codex_radar_die "Remote tag verification ref was not cleaned up"
}

assert_stale_local_tag_unchanged() {
  [[ "$(git -C "$CLIENT_DIR" rev-parse --verify \
    "refs/tags/v$MARKETING_VERSION")" == "$FIRST_COMMIT" ]] \
    || codex_radar_die "Local stale tag was overwritten by remote verification"
}

git init -q --bare "$REMOTE_DIR"
git init -q "$SOURCE_DIR"
git -C "$SOURCE_DIR" config user.name "Remote Tag Test"
git -C "$SOURCE_DIR" config user.email "remote-tag-test@example.com"
git -C "$SOURCE_DIR" remote add origin "$REMOTE_DIR"

printf 'first\n' > "$SOURCE_DIR/state.txt"
git -C "$SOURCE_DIR" add state.txt
git -C "$SOURCE_DIR" commit -q -m "first"
FIRST_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"

printf 'second\n' > "$SOURCE_DIR/state.txt"
git -C "$SOURCE_DIR" commit -q -am "second"
SECOND_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
git -C "$SOURCE_DIR" push -q origin HEAD:refs/heads/main

git init -q "$CLIENT_DIR"
git -C "$CLIENT_DIR" remote add origin "$REMOTE_DIR"
git -C "$CLIENT_DIR" fetch -q origin refs/heads/main:refs/remotes/origin/main

export MARKETING_VERSION="1.2.3"
git -C "$SOURCE_DIR" tag "v$MARKETING_VERSION" "$FIRST_COMMIT"
git -C "$SOURCE_DIR" push -q origin "refs/tags/v$MARKETING_VERSION"
assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$FIRST_COMMIT" \
  origin
assert_no_verification_refs

export MARKETING_VERSION="1.2.4"
git -C "$SOURCE_DIR" tag -a "v$MARKETING_VERSION" "$FIRST_COMMIT" -m "annotated"
git -C "$SOURCE_DIR" push -q origin "refs/tags/v$MARKETING_VERSION"
assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$FIRST_COMMIT" \
  origin
assert_no_verification_refs

export MARKETING_VERSION="1.2.3"
expect_failure \
  "wrong expected commit" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$SECOND_COMMIT" \
  origin
assert_no_verification_refs

git -C "$CLIENT_DIR" update-ref "refs/tags/v$MARKETING_VERSION" "$FIRST_COMMIT"
git -C "$SOURCE_DIR" tag -f "v$MARKETING_VERSION" "$SECOND_COMMIT" >/dev/null
git -C "$SOURCE_DIR" push -q --force origin "refs/tags/v$MARKETING_VERSION"
expect_failure \
  "force-moved remote tag" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$FIRST_COMMIT" \
  origin
assert_no_verification_refs
assert_stale_local_tag_unchanged
assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$SECOND_COMMIT" \
  origin
assert_no_verification_refs
assert_stale_local_tag_unchanged

git -C "$SOURCE_DIR" push -q origin ":refs/tags/v$MARKETING_VERSION"
expect_failure \
  "deleted remote tag with stale local tag" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$SECOND_COMMIT" \
  origin
assert_no_verification_refs
assert_stale_local_tag_unchanged

export MARKETING_VERSION="1.2.5"
BLOB_SHA="$(printf 'blob\n' | git -C "$SOURCE_DIR" hash-object -w --stdin)"
git -C "$SOURCE_DIR" update-ref "refs/tags/v$MARKETING_VERSION" "$BLOB_SHA"
git -C "$SOURCE_DIR" push -q origin "refs/tags/v$MARKETING_VERSION"
expect_failure \
  "remote tag does not peel to a commit" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$SECOND_COMMIT" \
  origin
assert_no_verification_refs

export MARKETING_VERSION="1.2.3"
expect_failure \
  "invalid release tag" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v1.2" \
  "$SECOND_COMMIT" \
  origin
expect_failure \
  "invalid expected commit SHA" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "${SECOND_COMMIT:0:12}" \
  origin
expect_failure \
  "missing remote" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$SECOND_COMMIT" \
  missing
git -C "$CLIENT_DIR" remote add broken "$TEST_DIR/missing-remote.git"
expect_failure \
  "remote fetch failure" \
  assert_remote_tag_commit \
  "$CLIENT_DIR" \
  "v$MARKETING_VERSION" \
  "$SECOND_COMMIT" \
  broken
assert_no_verification_refs

echo "remote_tag_test: PASS"
