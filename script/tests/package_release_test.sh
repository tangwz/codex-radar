#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

OUTPUT_DIR="$ROOT_DIR/tmp/package-release-test"
EXTRACT_DIR="$ROOT_DIR/tmp/package-release-extract"
FAILURE_OUTPUT_DIR="$ROOT_DIR/tmp/package-release-failure-test"
FAKE_BIN_DIR="$ROOT_DIR/tmp/package-release-fake-bin"
PATH_GUARD_DIR="$ROOT_DIR/tmp/package-release-path-guard"
SYMLINK_TARGET_DIR="$ROOT_DIR/tmp/package-release-symlink-target"
ESCAPE_PARENT="$(mktemp -d "$(dirname "$ROOT_DIR")/codex-radar-package-release-escape-test.XXXXXX")"
ESCAPE_DIR="$ESCAPE_PARENT/output"
trap 'rm -rf "$OUTPUT_DIR" "$EXTRACT_DIR" "$FAILURE_OUTPUT_DIR" "$FAKE_BIN_DIR" "$PATH_GUARD_DIR" "$SYMLINK_TARGET_DIR" "$ESCAPE_PARENT"' EXIT
rm -rf \
  "$OUTPUT_DIR" \
  "$EXTRACT_DIR" \
  "$FAILURE_OUTPUT_DIR" \
  "$FAKE_BIN_DIR" \
  "$PATH_GUARD_DIR" \
  "$SYMLINK_TARGET_DIR"

if (
  unset MACOS_SIGNING_IDENTITY
  unset APP_STORE_CONNECT_API_KEY_P8
  unset APP_STORE_CONNECT_KEY_ID
  unset APP_STORE_CONNECT_ISSUER_ID
  SIGNING_MODE=developer-id \
    RELEASE_PRERELEASE=false \
    "$ROOT_DIR/script/package_release.sh" "$OUTPUT_DIR"
); then
  echo "Expected developer-id packaging to reject missing credentials" >&2
  exit 1
fi
[[ ! -e "$OUTPUT_DIR" ]] \
  || codex_radar_die "Missing Developer ID credentials must not create output"

load_version "$ROOT_DIR/version.env"
FAILURE_ASSET="$FAILURE_OUTPUT_DIR/$(release_asset_name)"
FAILURE_CHECKSUM="$FAILURE_OUTPUT_DIR/$(release_checksum_name)"
mkdir -p "$FAILURE_OUTPUT_DIR" "$FAKE_BIN_DIR"
touch "$FAILURE_ASSET" "$FAILURE_CHECKSUM"
cat > "$FAKE_BIN_DIR/swift" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
chmod +x "$FAKE_BIN_DIR/swift"

if PATH="$FAKE_BIN_DIR:$PATH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" "$FAILURE_OUTPUT_DIR"; then
  echo "Expected packaging to fail when the build fails" >&2
  exit 1
fi
[[ ! -e "$FAILURE_ASSET" && ! -e "$FAILURE_CHECKSUM" ]] \
  || codex_radar_die "Failed packaging must not leave final release assets"

mkdir -p "$PATH_GUARD_DIR" "$SYMLINK_TARGET_DIR"
ln -s "$SYMLINK_TARGET_DIR" "$PATH_GUARD_DIR/symlink"
if SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" \
  "$PATH_GUARD_DIR/symlink/output"; then
  echo "Expected a symbolic-link output parent to be rejected" >&2
  exit 1
fi
[[ ! -e "$SYMLINK_TARGET_DIR/output" ]] \
  || codex_radar_die "Symbolic-link output must be rejected before creating directories"

touch "$PATH_GUARD_DIR/not-a-directory"
if SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" \
  "$PATH_GUARD_DIR/not-a-directory/output"; then
  echo "Expected a non-directory output component to be rejected" >&2
  exit 1
fi

if SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" \
  "../$(basename "$ESCAPE_PARENT")/$(basename "$ESCAPE_DIR")"; then
  echo "Expected traversal output to be rejected" >&2
  exit 1
fi
[[ ! -e "$ESCAPE_DIR" ]] \
  || codex_radar_die "Traversal output must not create directories outside the repository"

SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" "tmp/$(basename "$OUTPUT_DIR")"

ASSET="$OUTPUT_DIR/$(release_asset_name)"
CHECKSUM="$OUTPUT_DIR/$(release_checksum_name)"
[[ -f "$ASSET" ]]
[[ -f "$CHECKSUM" ]]
[[ ! -e "$OUTPUT_DIR/$APP_NAME.app" ]] \
  || codex_radar_die "Final release output must not contain the working app bundle"

(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ASSET" "$EXTRACT_DIR"
[[ "$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" == "1" ]]
SIGNING_MODE=adhoc \
  "$ROOT_DIR/script/verify_app.sh" \
  "$EXTRACT_DIR/CodexRadar.app" \
  arm64 \
  x86_64

echo "package_release_test: PASS"
