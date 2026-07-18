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

printf '%s\n' "$*" >> "$GH_LOG"
if [[ "$1" == "release" && "$2" == "view" ]]; then
  if [[ "$*" == *"--json body"* ]]; then
    printf '%s\n' "$FAKE_GH_BODY"
    exit 0
  fi
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
elif [[ "$1" == "release" && "$2" == "upload" ]]; then
  [[ "${FAKE_GH_UPLOAD_FAIL:-false}" != "true" ]]
fi
FAKE
chmod +x "$FAKE_GH"

load_version "$ROOT_DIR/version.env"
ASSET="$TEST_DIR/$(release_asset_name)"
CHECKSUM="$TEST_DIR/$(release_checksum_name)"
printf 'asset\n' > "$ASSET"

write_checksum() {
  (
    cd "$TEST_DIR"
    /usr/bin/shasum -a 256 "$(basename "$ASSET")" > "$(basename "$CHECKSUM")"
  )
}

run_publish() {
  FAKE_GH_STATE="$1" \
  FAKE_GH_BODY="${FAKE_GH_BODY:-$(cat "$ROOT_DIR/.github/release-notes-adhoc.md")}" \
  GH_LOG="$GH_LOG" \
  GH_BIN="$FAKE_GH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
    "$ROOT_DIR/script/publish_release.sh" \
    "v$MARKETING_VERSION" \
    "$ASSET" \
    "$CHECKSUM"
}

assert_not_logged() {
  local pattern="$1"
  if grep -Fq "$pattern" "$GH_LOG"; then
    echo "Unexpected GitHub command matching: $pattern" >&2
    exit 1
  fi
}

assert_publish_order() {
  local create_line="$1"
  local upload_line="$2"
  local edit_line="$3"
  [[ "$create_line" -lt "$upload_line" && "$upload_line" -lt "$edit_line" ]] \
    || codex_radar_die "Release must be created, uploaded, then published"
}

write_checksum
: > "$GH_LOG"
run_publish missing
grep -Fq "release create v$MARKETING_VERSION" "$GH_LOG"
grep -Fq -- "--draft --verify-tag" "$GH_LOG"
grep -Fq "release upload v$MARKETING_VERSION $ASSET $CHECKSUM --clobber" "$GH_LOG"
grep -Fq "release edit v$MARKETING_VERSION --draft=false --prerelease" "$GH_LOG"
assert_publish_order \
  "$(grep -n -m 1 "release create v$MARKETING_VERSION" "$GH_LOG" | cut -d: -f1)" \
  "$(grep -n -m 1 "release upload v$MARKETING_VERSION" "$GH_LOG" | cut -d: -f1)" \
  "$(grep -n -m 1 "release edit v$MARKETING_VERSION" "$GH_LOG" | cut -d: -f1)"

: > "$GH_LOG"
run_publish draft
assert_not_logged "release create"
grep -Fq "release upload v$MARKETING_VERSION" "$GH_LOG"
grep -Fq "release edit v$MARKETING_VERSION --draft=false --prerelease" "$GH_LOG"

: > "$GH_LOG"
if FAKE_GH_BODY="Draft without the required warning" run_publish draft-missing-warning; then
  echo "Ad-hoc drafts without the warning must not be published" >&2
  exit 1
fi
assert_not_logged "release upload"
assert_not_logged "release edit"

: > "$GH_LOG"
if run_publish public; then
  echo "Published releases must not be overwritten" >&2
  exit 1
fi
assert_not_logged "release create"
assert_not_logged "release upload"
assert_not_logged "release edit"

: > "$GH_LOG"
if run_publish view-error; then
  echo "GitHub view errors must fail closed" >&2
  exit 1
fi
assert_not_logged "release create"
assert_not_logged "release upload"
assert_not_logged "release edit"

: > "$GH_LOG"
if run_publish malformed; then
  echo "Unexpected GitHub release states must fail closed" >&2
  exit 1
fi
assert_not_logged "release create"
assert_not_logged "release upload"
assert_not_logged "release edit"

: > "$GH_LOG"
if FAKE_GH_UPLOAD_FAIL=true run_publish missing; then
  echo "Upload failures must stop publication" >&2
  exit 1
fi
grep -Fq "release create v$MARKETING_VERSION" "$GH_LOG"
grep -Fq "release upload v$MARKETING_VERSION" "$GH_LOG"
assert_not_logged "release edit"

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
