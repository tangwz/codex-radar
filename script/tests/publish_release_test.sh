#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-publish-release.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FAKE_GH="$TEST_DIR/gh"
GH_LOG="$TEST_DIR/gh.log"

cat > "$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

reject_command() {
  echo "Unexpected fake GitHub command" >&2
  exit 2
}

accept_command() {
  printf 'accepted %s\n' "$1" >> "$GH_LOG"
}

printf 'attempt %s %s\n' "${1:-<missing>}" "${2:-<missing>}" >> "$GH_LOG"
[[ $# -ge 2 ]] || reject_command
[[ "$1" == "release" ]] || reject_command

case "$2" in
  view)
    [[ $# -eq 7 ]] || reject_command
    [[ "$3" == "$EXPECTED_TAG" && "$4" == "--json" && "$6" == "--jq" ]] \
      || reject_command
    if [[ "$5" == "isDraft" && "$7" == ".isDraft" ]]; then
      accept_command "release view state"
      case "$FAKE_GH_STATE" in
        missing)
          echo "release not found" >&2
          exit 1
          ;;
        draft | draft-missing-warning)
          printf 'true\n'
          ;;
        public)
          printf 'false\n'
          ;;
        malformed)
          printf 'unknown\n'
          ;;
        view-error)
          echo "authentication failed" >&2
          exit 1
          ;;
        *)
          echo "Unexpected fake GitHub state: $FAKE_GH_STATE" >&2
          exit 2
          ;;
      esac
    elif [[ "$5" == "body" && "$7" == ".body" ]]; then
      [[ "$FAKE_GH_STATE" == "draft" || "$FAKE_GH_STATE" == "draft-missing-warning" ]] \
        || reject_command
      accept_command "release view body"
      printf '%s\n' "$FAKE_GH_BODY"
    else
      reject_command
    fi
    ;;
  create)
    [[ $# -eq 10 ]] || reject_command
    [[ "$3" == "$EXPECTED_TAG" \
      && "$4" == "--draft" \
      && "$5" == "--verify-tag" \
      && "$6" == "--title" \
      && "$7" == "Codex Radar $EXPECTED_TAG" \
      && "$8" == "--generate-notes" \
      && "$9" == "--notes" \
      && "${10}" == "$EXPECTED_NOTES" ]] \
      || reject_command
    accept_command "release create"
    ;;
  upload)
    [[ $# -eq 6 ]] || reject_command
    [[ "$3" == "$EXPECTED_TAG" \
      && "$4" == "$EXPECTED_ASSET" \
      && "$5" == "$EXPECTED_CHECKSUM" \
      && "$6" == "--clobber" ]] \
      || reject_command
    accept_command "release upload"
    [[ "${FAKE_GH_UPLOAD_FAIL:-false}" != "true" ]]
    ;;
  edit)
    [[ $# -eq 5 ]] || reject_command
    [[ "$3" == "$EXPECTED_TAG" && "$4" == "--draft=false" ]] \
      || reject_command
    [[ "$5" == "$EXPECTED_PRERELEASE_FLAG" ]] || reject_command
    accept_command "release edit"
    ;;
  *)
    reject_command
    ;;
esac
FAKE
chmod +x "$FAKE_GH"

load_version "$ROOT_DIR/version.env"
ASSET="$TEST_DIR/$(release_asset_name)"
CHECKSUM="$TEST_DIR/$(release_checksum_name)"
printf 'asset\n' > "$ASSET"

expect_fake_protocol_rejection() {
  local status=0
  set +e
  FAKE_GH_STATE=draft \
    EXPECTED_TAG="v$MARKETING_VERSION" \
    EXPECTED_ASSET="$ASSET" \
    EXPECTED_CHECKSUM="$CHECKSUM" \
    EXPECTED_NOTES="$(cat "$ROOT_DIR/.github/release-notes-adhoc.md")" \
    EXPECTED_PRERELEASE_FLAG="--prerelease" \
    GH_LOG="$GH_LOG" \
    "$FAKE_GH" "$@" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" == "2" ]] \
    || codex_radar_die "Fake GitHub protocol violations must exit 2"
}

expect_fake_protocol_rejection \
  release upload "v$MARKETING_VERSION" "$ASSET" "$CHECKSUM" --clobber --unexpected
expect_fake_protocol_rejection release view "v$MARKETING_VERSION" --json isDraft --jq
expect_fake_protocol_rejection api unexpected

write_checksum() {
  (
    cd "$TEST_DIR"
    /usr/bin/shasum -a 256 "$(basename "$ASSET")" > "$(basename "$CHECKSUM")"
  )
}

run_publish() {
  FAKE_GH_STATE="$1" \
  FAKE_GH_BODY="${FAKE_GH_BODY:-$(cat "$ROOT_DIR/.github/release-notes-adhoc.md")}" \
  EXPECTED_TAG="v$MARKETING_VERSION" \
  EXPECTED_ASSET="$ASSET" \
  EXPECTED_CHECKSUM="$CHECKSUM" \
  EXPECTED_NOTES="$(cat "$ROOT_DIR/.github/release-notes-adhoc.md")" \
  EXPECTED_PRERELEASE_FLAG="--prerelease" \
  GH_LOG="$GH_LOG" \
  GH_BIN="$FAKE_GH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
    "$ROOT_DIR/script/publish_release.sh" \
    "v$MARKETING_VERSION" \
    "$ASSET" \
    "$CHECKSUM"
}

assert_log() {
  local expected=""
  expected="$(printf '%s\n' "$@")"
  [[ "$(cat "$GH_LOG")" == "$expected" ]] \
    || codex_radar_die "Unexpected fake GitHub command log"
}

write_checksum
: > "$GH_LOG"
run_publish missing
assert_log \
  "attempt release view" \
  "accepted release view state" \
  "attempt release create" \
  "accepted release create" \
  "attempt release upload" \
  "accepted release upload" \
  "attempt release edit" \
  "accepted release edit"

: > "$GH_LOG"
run_publish draft
assert_log \
  "attempt release view" \
  "accepted release view state" \
  "attempt release view" \
  "accepted release view body" \
  "attempt release upload" \
  "accepted release upload" \
  "attempt release edit" \
  "accepted release edit"

: > "$GH_LOG"
if FAKE_GH_BODY="Draft without the required warning" run_publish draft-missing-warning; then
  echo "Ad-hoc drafts without the warning must not be published" >&2
  exit 1
fi
assert_log \
  "attempt release view" \
  "accepted release view state" \
  "attempt release view" \
  "accepted release view body"

: > "$GH_LOG"
if run_publish public; then
  echo "Published releases must not be overwritten" >&2
  exit 1
fi
assert_log \
  "attempt release view" \
  "accepted release view state"

: > "$GH_LOG"
if run_publish view-error; then
  echo "GitHub view errors must fail closed" >&2
  exit 1
fi
assert_log \
  "attempt release view" \
  "accepted release view state"

: > "$GH_LOG"
if run_publish malformed; then
  echo "Unexpected GitHub release states must fail closed" >&2
  exit 1
fi
assert_log \
  "attempt release view" \
  "accepted release view state"

: > "$GH_LOG"
if FAKE_GH_UPLOAD_FAIL=true run_publish missing; then
  echo "Upload failures must stop publication" >&2
  exit 1
fi
assert_log \
  "attempt release view" \
  "accepted release view state" \
  "attempt release create" \
  "accepted release create" \
  "attempt release upload" \
  "accepted release upload"

: > "$GH_LOG"
if FAKE_GH_STATE=missing \
  GH_LOG="$GH_LOG" \
  GH_BIN="$FAKE_GH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=false \
    "$ROOT_DIR/script/publish_release.sh" \
    "v$MARKETING_VERSION" \
    "$ASSET" \
    "$CHECKSUM"; then
  echo "Ad-hoc stable releases must be rejected" >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]] \
  || codex_radar_die "Release channel validation must run before GitHub access"

: > "$GH_LOG"
printf 'tampered asset\n' > "$ASSET"
if run_publish missing; then
  echo "Checksum mismatches must be rejected" >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]] \
  || codex_radar_die "Checksum validation must run before GitHub access"

printf 'asset\n' > "$ASSET"
write_checksum
: > "$GH_LOG"
OTHER_ASSET="$TEST_DIR/other.zip"
printf 'other asset\n' > "$OTHER_ASSET"
(
  cd "$TEST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$OTHER_ASSET")" > "$(basename "$CHECKSUM")"
)
if run_publish missing; then
  echo "Checksums for other files must be rejected" >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]] \
  || codex_radar_die "Checksum target validation must run before GitHub access"

write_checksum
: > "$GH_LOG"
(
  cd "$TEST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$OTHER_ASSET")" >> "$(basename "$CHECKSUM")"
)
if run_publish missing; then
  echo "Multi-record checksum files must be rejected" >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]] \
  || codex_radar_die "Checksum record validation must run before GitHub access"

write_checksum
: > "$GH_LOG"
WRONG_ASSET="$TEST_DIR/wrong.zip"
cp "$ASSET" "$WRONG_ASSET"
if FAKE_GH_STATE=missing \
  GH_LOG="$GH_LOG" \
  GH_BIN="$FAKE_GH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
    "$ROOT_DIR/script/publish_release.sh" \
    "v$MARKETING_VERSION" \
    "$WRONG_ASSET" \
    "$CHECKSUM"; then
  echo "Unexpected asset names must be rejected" >&2
  exit 1
fi
[[ ! -s "$GH_LOG" ]] \
  || codex_radar_die "Asset name validation must run before GitHub access"

echo "publish_release_test: PASS"
