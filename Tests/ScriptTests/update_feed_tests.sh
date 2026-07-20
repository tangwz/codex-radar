#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE_SCRIPT="$ROOT_DIR/script/prepare_appcast_inputs.sh"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_update_artifacts.sh"
SPARKLE_SOURCE="$ROOT_DIR/.build/checkouts/Sparkle"
SPARKLE_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"

[[ -x "$PREPARE_SCRIPT" ]] || {
  echo "prepare_appcast_inputs.sh does not exist" >&2
  exit 1
}
[[ -x "$VERIFY_SCRIPT" ]] || {
  echo "verify_update_artifacts.sh does not exist" >&2
  exit 1
}
[[ -d "$SPARKLE_SOURCE" ]] || {
  echo "Sparkle source checkout does not exist" >&2
  exit 1
}

fixture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-feed-tests.XXXXXX")"
sparkle_source_file="Vendor/ed25519-sparkle/src/fe.c"

cleanup() {
  /bin/rm -rf "$fixture_root"
}
trap cleanup EXIT

fail() {
  echo "$*" >&2
  exit 1
}

expect_failure() {
  local expected_message="$1"
  shift
  local output_path="$fixture_root/failure-output"

  if "$@" >"$output_path" 2>&1; then
    fail "fixture unexpectedly succeeded: $expected_message"
  fi
  /usr/bin/grep -F "$expected_message" "$output_path" >/dev/null || {
    /bin/cat "$output_path" >&2
    fail "fixture did not report: $expected_message"
  }
}

write_version_config() {
  local path="$1" version="$2" build="$3"

  printf 'MARKETING_VERSION=%s\nBUILD_NUMBER=%s\n' "$version" "$build" >"$path"
}

write_update_config() {
  local path="$1" public_key="$2"

  {
    printf 'SPARKLE_VERSION=2.9.4\n'
    printf 'SPARKLE_PUBLIC_ED_KEY=%s\n' "$public_key"
    printf 'PRODUCTION_FEED_URL=https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml\n'
  } >"$path"
}

build_test_signer() {
  local source_dir="$SPARKLE_SOURCE/Vendor/ed25519-sparkle/src"

  /usr/bin/xcrun clang -std=c11 -Wall -Wextra -Werror \
    -I "$source_dir" \
    "$source_dir/fe.c" \
    "$source_dir/ge.c" \
    "$source_dir/sc.c" \
    "$source_dir/sha512.c" \
    "$source_dir/keypair.c" \
    "$source_dir/sign.c" \
    -x c - -o "$fixture_root/test-signer" <<'C'
#include "ed25519.h"

#include <stdio.h>
#include <stdlib.h>

static unsigned char *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long size;
    unsigned char *bytes;

    if (file == NULL || fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET) != 0) {
        return NULL;
    }
    bytes = malloc((size_t)size + 1);
    if (bytes == NULL || fread(bytes, 1, (size_t)size, file) != (size_t)size ||
        fclose(file) != 0) {
        free(bytes);
        return NULL;
    }
    *length = (size_t)size;
    return bytes;
}

static int write_file(const char *path, const unsigned char *bytes, size_t length) {
    FILE *file = fopen(path, "wb");
    int result;

    if (file == NULL) {
        return 0;
    }
    result = fwrite(bytes, 1, length, file) == length && fclose(file) == 0;
    return result;
}

int main(int argc, char **argv) {
    unsigned char seed[32];
    unsigned char public_key[32];
    unsigned char private_key[64];
    unsigned char signature[64];
    unsigned char *message;
    size_t seed_length;
    size_t message_length;
    unsigned char *seed_bytes;

    if (argc != 5) {
        return 2;
    }
    seed_bytes = read_file(argv[1], &seed_length);
    message = read_file(argv[2], &message_length);
    if (seed_bytes == NULL || message == NULL || seed_length != sizeof(seed)) {
        free(seed_bytes);
        free(message);
        return 1;
    }
    for (size_t index = 0; index < sizeof(seed); index++) {
        seed[index] = seed_bytes[index];
    }
    free(seed_bytes);
    ed25519_create_keypair(public_key, private_key, seed);
    ed25519_sign(signature, message, message_length, public_key, private_key);
    free(message);
    if (!write_file(argv[3], public_key, sizeof(public_key)) ||
        !write_file(argv[4], signature, sizeof(signature))) {
        return 1;
    }
    return 0;
}
C
}

sign_file() {
  local input_path="$1"

  "$fixture_root/test-signer" "$fixture_root/test-seed" "$input_path" \
    "$fixture_root/public-key.raw" "$fixture_root/signature.raw"
  /usr/bin/base64 <"$fixture_root/signature.raw" | /usr/bin/tr -d '\n'
}

write_info_plist() {
  local path="$1" version="$2" build="$3" minimum_system="$4" public_key="$5"

  /bin/mkdir -p "$(/usr/bin/dirname "$path")"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0"><dict>'
    printf '%s\n' '<key>CFBundleIdentifier</key><string>com.terence.codex-radar</string>'
    printf '<key>CFBundleShortVersionString</key><string>%s</string>\n' "$version"
    printf '<key>CFBundleVersion</key><string>%s</string>\n' "$build"
    printf '<key>LSMinimumSystemVersion</key><string>%s</string>\n' "$minimum_system"
    printf '%s\n' '<key>SUFeedURL</key><string>https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml</string>'
    printf '<key>SUPublicEDKey</key><string>%s</string>\n' "$public_key"
    printf '%s\n' '<key>SUEnableAutomaticChecks</key><true/>'
    printf '%s\n' '<key>SUAutomaticallyUpdate</key><true/>'
    printf '%s\n' '<key>SUVerifyUpdateBeforeExtraction</key><true/>'
    printf '%s\n' '<key>SURequireSignedFeed</key><true/>'
    printf '%s\n' '<key>CodexRadarUpdatesEnabled</key><true/>'
    printf '%s\n' '</dict></plist>'
  } >"$path"
  /usr/bin/plutil -lint "$path" >/dev/null
}

make_release_fixture() {
  local directory="$1" version="$2" build="$3" minimum_system="$4"
  local archive_name="CodexRadar-v${version}-macos-universal.zip"
  local app_path="$directory/app/CodexRadar.app"
  local archive_path="$directory/$archive_name"
  local manifest_path="$archive_path.manifest"
  local info_plist="$directory/final-Info.plist"
  local archive_sha archive_length

  /bin/mkdir -p "$app_path/Contents/MacOS"
  write_info_plist "$info_plist" "$version" "$build" "$minimum_system" "$PUBLIC_KEY"
  /bin/cp "$info_plist" "$app_path/Contents/Info.plist"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$app_path/Contents/MacOS/CodexRadar"
  /bin/chmod 755 "$app_path/Contents/MacOS/CodexRadar"
  /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$app_path" "$archive_path"
  archive_sha="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
  archive_length="$(/usr/bin/stat -f '%z' "$archive_path")"
  {
    printf 'archive_name=%s\n' "$archive_name"
    printf 'version=%s\n' "$version"
    printf 'build=%s\n' "$build"
    printf 'byte_length=%s\n' "$archive_length"
    printf 'sha256=%s\n' "$archive_sha"
    printf 'signing_mode=adhoc\n'
    printf 'distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted\n'
  } >"$manifest_path"
}

make_feed() {
  local output_path="$1" version="$2" build="$3" minimum_system="$4"
  local enclosure_url="$5" enclosure_length="$6" archive_signature="$7"
  local extra_item_xml="${8:-}" second_entry="${9:-false}"
  local content_path="$output_path.content" feed_signature content_length

  {
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
    printf '<rss xmlns:sparkle="%s" version="2.0">\n' "$SPARKLE_NAMESPACE"
    printf '%s\n' '<channel><title>CodexRadar</title><item>'
    printf '<title>%s</title>\n' "$version"
    printf '<sparkle:version>%s</sparkle:version>\n' "$build"
    printf '<sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$version"
    printf '<sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$minimum_system"
    printf '%s\n' "$extra_item_xml"
    if [[ "$archive_signature" == absent ]]; then
      printf '<enclosure url="%s" length="%s" type="application/octet-stream"/>\n' \
        "$enclosure_url" "$enclosure_length"
    else
      printf '<enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/>\n' \
        "$enclosure_url" "$enclosure_length" "$archive_signature"
    fi
    printf '%s\n' '</item>'
    if [[ "$second_entry" == true ]]; then
      printf '%s\n' '<item><sparkle:version>1</sparkle:version></item>'
    fi
    printf '%s\n' '</channel></rss>'
  } >"$content_path"
  feed_signature="$(sign_file "$content_path")"
  content_length="$(/usr/bin/stat -f '%z' "$content_path")"
  /bin/cp "$content_path" "$output_path"
  printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
    "$feed_signature" "$content_length" >>"$output_path"
  /bin/rm -f "$content_path"
}

prepare_command() {
  local output_path="$1" version_config="$2" update_config="$3"
  local archive_path="$4" manifest_path="$5" info_plist="$6"
  shift 6

  "$PREPARE_SCRIPT" \
    --output "$output_path" \
    --archive "$archive_path" \
    --manifest "$manifest_path" \
    --final-info-plist "$info_plist" \
    --version-config "$version_config" \
    --update-config "$update_config" \
    --sparkle-source "$SPARKLE_SOURCE" \
    "$@"
}

verify_artifacts() {
  verify_artifacts_with_sparkle "$SPARKLE_SOURCE" "$@"
}

verify_artifacts_with_sparkle() {
  local sparkle_source="$1"
  shift
  local inputs_path="$1" archive_path="$2" manifest_path="$3" info_plist="$4"
  local version_config="$5" update_config="$6"

  "$VERIFY_SCRIPT" --mode artifacts \
    --inputs "$inputs_path" \
    --archive "$archive_path" \
    --manifest "$manifest_path" \
    --final-info-plist "$info_plist" \
    --version-config "$version_config" \
    --update-config "$update_config" \
    --sparkle-source "$sparkle_source"
}

printf '01234567890123456789012345678901' >"$fixture_root/test-seed"
build_test_signer
: >"$fixture_root/empty"
sign_file "$fixture_root/empty" >/dev/null
PUBLIC_KEY="$(/usr/bin/base64 <"$fixture_root/public-key.raw" | /usr/bin/tr -d '\n')"

candidate_dir="$fixture_root/candidate"
previous_dir="$fixture_root/previous"
/bin/mkdir -p "$candidate_dir" "$previous_dir"
write_version_config "$candidate_dir/version.env" 0.2.0 2
write_update_config "$candidate_dir/update.env" "$PUBLIC_KEY"
make_release_fixture "$candidate_dir" 0.2.0 2 14.0
candidate_archive="$candidate_dir/CodexRadar-v0.2.0-macos-universal.zip"
candidate_manifest="$candidate_archive.manifest"
candidate_info="$candidate_dir/final-Info.plist"
archive_length="$(/usr/bin/stat -f '%z' "$candidate_archive")"
archive_signature="$(sign_file "$candidate_archive")"
previous_url="https://github.com/tangwz/codex-radar/releases/download/v0.1.0/CodexRadar-v0.1.0-macos-universal.zip"
make_feed "$previous_dir/appcast.xml" 0.1.0 1 14.0 "$previous_url" 123 "$archive_signature"
printf '[]\n' >"$fixture_root/empty-history.json"
printf '[{"tag_name":"v0.0.1"}]\n' >"$fixture_root/nonempty-history.json"

inputs_dir="$fixture_root/inputs"
prepare_command "$inputs_dir" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$previous_dir/appcast.xml"

archive_name="CodexRadar-v0.2.0-macos-universal.zip"
/usr/bin/cmp -s "$candidate_archive" "$inputs_dir/production/$archive_name" ||
  fail "production archive bytes changed during preparation"
/usr/bin/cmp -s "$candidate_archive" "$inputs_dir/qualification/$archive_name" ||
  fail "qualification archive bytes changed during preparation"
/usr/bin/cmp -s "$inputs_dir/production/$archive_name" "$inputs_dir/qualification/$archive_name" ||
  fail "production and qualification archives differ"
/usr/bin/cmp -s "$candidate_manifest" "$inputs_dir/manifest" ||
  fail "manifest bytes changed during preparation"
/usr/bin/cmp -s "$candidate_info" "$inputs_dir/Info.plist" ||
  fail "Info.plist bytes changed during preparation"
/usr/bin/cmp -s "$previous_dir/appcast.xml" "$inputs_dir/previous-appcast.xml" ||
  fail "previous signed feed bytes changed during preparation"
/usr/bin/cmp -s "$previous_dir/appcast.xml" "$inputs_dir/production/appcast.xml" ||
  fail "production seed feed bytes changed during preparation"
/usr/bin/cmp -s "$previous_dir/appcast.xml" "$inputs_dir/qualification/appcast.xml" ||
  fail "qualification seed feed bytes changed during preparation"
[[ "$(<"$inputs_dir/production-download-url-prefix")" == \
  "https://github.com/tangwz/codex-radar/releases/download/v0.2.0/" ]] ||
  fail "production URL prefix is not version-fixed"
[[ "$(<"$inputs_dir/qualification-download-url-prefix")" == "./" ]] ||
  fail "qualification URL prefix is not relative"
if /usr/bin/find "$inputs_dir" -type f \( -name '*.html' -o -name '*.md' -o -name '*.markdown' -o -name '*.txt' \) | /usr/bin/grep . >/dev/null; then
  fail "preparation unexpectedly created release notes"
fi

missing_feed_output="$fixture_root/missing-feed-output"
expect_failure "existing Production Feed is required" prepare_command \
  "$missing_feed_output" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info"

non_increasing_previous="$fixture_root/non-increasing.xml"
make_feed "$non_increasing_previous" 0.2.0 2 14.0 \
  "https://github.com/tangwz/codex-radar/releases/download/v0.2.0/$archive_name" \
  "$archive_length" "$archive_signature"
expect_failure "candidate build must be greater than Production Feed build" prepare_command \
  "$fixture_root/non-increasing-output" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$non_increasing_previous"

lower_minimum_previous="$fixture_root/lower-minimum.xml"
make_feed "$lower_minimum_previous" 0.1.0 1 13.0 "$previous_url" 123 "$archive_signature"
expect_failure "minimum system version must match the Production Feed" prepare_command \
  "$fixture_root/lower-minimum-output" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$lower_minimum_previous"

bootstrap_dir="$fixture_root/bootstrap"
/bin/mkdir -p "$bootstrap_dir"
write_version_config "$bootstrap_dir/version.env" 0.1.0 1
write_update_config "$bootstrap_dir/update.env" "$PUBLIC_KEY"
make_release_fixture "$bootstrap_dir" 0.1.0 1 14.0
bootstrap_archive="$bootstrap_dir/CodexRadar-v0.1.0-macos-universal.zip"
bootstrap_inputs="$fixture_root/bootstrap-inputs"
prepare_command "$bootstrap_inputs" "$bootstrap_dir/version.env" "$bootstrap_dir/update.env" \
  "$bootstrap_archive" "$bootstrap_archive.manifest" "$bootstrap_dir/final-Info.plist" \
  --bootstrap --release-history "$fixture_root/empty-history.json"
[[ -f "$bootstrap_inputs/bootstrap" ]] || fail "bootstrap marker is missing"
[[ ! -e "$bootstrap_inputs/previous-appcast.xml" ]] ||
  fail "bootstrap preparation created a previous feed"
[[ ! -e "$bootstrap_inputs/production/appcast.xml" ]] ||
  fail "bootstrap preparation seeded a production feed"

expect_failure "bootstrap requires App Version 0.1.0 and build 1" prepare_command \
  "$fixture_root/bootstrap-wrong-version" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --bootstrap --release-history "$fixture_root/empty-history.json"
expect_failure "bootstrap requires an absent Production Feed" prepare_command \
  "$fixture_root/bootstrap-with-feed" "$bootstrap_dir/version.env" "$bootstrap_dir/update.env" \
  "$bootstrap_archive" "$bootstrap_archive.manifest" "$bootstrap_dir/final-Info.plist" \
  --bootstrap --production-feed "$previous_dir/appcast.xml" \
  --release-history "$fixture_root/empty-history.json"
expect_failure "bootstrap requires empty GitHub Release history" prepare_command \
  "$fixture_root/bootstrap-with-history" "$bootstrap_dir/version.env" "$bootstrap_dir/update.env" \
  "$bootstrap_archive" "$bootstrap_archive.manifest" "$bootstrap_dir/final-Info.plist" \
  --bootstrap --release-history "$fixture_root/nonempty-history.json"

bad_trust_manifest="$fixture_root/bad-trust.manifest"
/usr/bin/sed \
  's/distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted/distribution_trust=developer-id-notarized/' \
  "$candidate_manifest" >"$bad_trust_manifest"
expect_failure "invalid manifest signing trust" prepare_command \
  "$fixture_root/bad-trust-inputs" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$bad_trust_manifest" "$candidate_info" \
  --production-feed "$previous_dir/appcast.xml"

production_url="https://github.com/tangwz/codex-radar/releases/download/v0.2.0/$archive_name"
make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature"

production_feed_sha="$(/usr/bin/shasum -a 256 "$inputs_dir/production/appcast.xml" | /usr/bin/awk '{print $1}')"
qualification_feed_sha="$(/usr/bin/shasum -a 256 "$inputs_dir/qualification/appcast.xml" | /usr/bin/awk '{print $1}')"
verify_artifacts "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
[[ "$production_feed_sha" == "$(/usr/bin/shasum -a 256 "$inputs_dir/production/appcast.xml" | /usr/bin/awk '{print $1}')" ]] ||
  fail "verification changed signed production feed bytes"
[[ "$qualification_feed_sha" == "$(/usr/bin/shasum -a 256 "$inputs_dir/qualification/appcast.xml" | /usr/bin/awk '{print $1}')" ]] ||
  fail "verification changed signed qualification feed bytes"

assert_artifact_failure() {
  local expected_message="$1"

  expect_failure "$expected_message" verify_artifacts \
    "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
    "$candidate_dir/version.env" "$candidate_dir/update.env"
}

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 3 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
assert_artifact_failure "sparkle:version does not match version.env"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "https://github.com/tangwz/codex-radar/releases/latest/download/$archive_name" \
  "$archive_length" "$archive_signature"
assert_artifact_failure "production enclosure URL must be version-fixed"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$((archive_length + 1))" "$archive_signature"
assert_artifact_failure "enclosure length does not match archive"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" absent
assert_artifact_failure "enclosure is missing an Ed25519 signature"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
printf ' ' >>"$inputs_dir/production/appcast.xml"
assert_artifact_failure "invalid signed feed block"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
/usr/bin/tail -n 4 "$inputs_dir/production/appcast.xml" >"$fixture_root/original-feed-block"
/usr/bin/python3 - "$inputs_dir/production/appcast.xml" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
marker = b"<!-- sparkle-signatures:\n"
content, block = data.rsplit(marker, 1)
if b"CodexRadar" not in content:
    raise SystemExit("fixture feed does not contain a mutable signed byte")
path.write_bytes(content.replace(b"CodexRadar", b"CodexQadar", 1) + marker + block)
PYTHON
/usr/bin/tail -n 4 "$inputs_dir/production/appcast.xml" >"$fixture_root/mutated-feed-block"
/usr/bin/cmp -s "$fixture_root/original-feed-block" "$fixture_root/mutated-feed-block" ||
  fail "signed feed mutation changed the signature block"
assert_artifact_failure "production signed feed failed Ed25519 verification"

wrong_signature="$(sign_file "$fixture_root/empty")"
make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$wrong_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$wrong_signature"
assert_artifact_failure "production archive failed Ed25519 verification"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
wrong_signature="$(sign_file "$fixture_root/empty")"
/usr/bin/python3 - "$inputs_dir/production/appcast.xml" "$wrong_signature" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
signature = sys.argv[2].encode("ascii")
data = path.read_bytes()
prefix = b"edSignature: "
start = data.rfind(prefix)
end = data.find(b"\n", start)
if start < 0 or end < 0:
    raise SystemExit("fixture feed signature block is missing")
path.write_bytes(data[:start] + prefix + signature + data[end:])
PYTHON
assert_artifact_failure "production signed feed failed Ed25519 verification"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "https://example.invalid/$archive_name" "$archive_length" "$archive_signature"
assert_artifact_failure "qualification enclosure URL must be relative"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 15.0 \
  "$archive_name" "$archive_length" "$archive_signature"
assert_artifact_failure "minimum system version does not match final Info.plist"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" \
  '<sparkle:deltas><enclosure sparkle:deltaFrom="1"/></sparkle:deltas>'
assert_artifact_failure "feed must not contain deltas"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" \
  '<sparkle:channel>beta</sparkle:channel>'
assert_artifact_failure "feed must not contain a channel"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" \
  '<description>Changed</description>'
assert_artifact_failure "feed must not contain release notes"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" '' true
assert_artifact_failure "feed must contain exactly one entry"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature"
bad_manifest="$fixture_root/bad.manifest"
/bin/cp "$candidate_manifest" "$bad_manifest"
printf 'unexpected=true\n' >>"$bad_manifest"
expect_failure "manifest bytes differ from prepared inputs" verify_artifacts \
  "$inputs_dir" "$candidate_archive" "$bad_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"

different_info="$fixture_root/different-Info.plist"
/bin/cp "$candidate_info" "$different_info"
printf '\n' >>"$different_info"
expect_failure "Info.plist bytes differ from prepared inputs" verify_artifacts \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$different_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"

unknown_feed="$fixture_root/unknown-feed.xml"
make_feed "$unknown_feed" 9.9.9 999 14.0 \
  "https://github.com/tangwz/codex-radar/releases/download/v9.9.9/unknown.zip" \
  99 "$archive_signature"

cas_output="$fixture_root/cas-output"
"$VERIFY_SCRIPT" --mode cas \
  --current-feed "$inputs_dir/previous-appcast.xml" \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml" >"$cas_output"
/usr/bin/grep -Fx 'cas_state=ready' "$cas_output" >/dev/null || fail "CAS ready state was not reported"

"$VERIFY_SCRIPT" --mode cas \
  --current-feed "$inputs_dir/production/appcast.xml" \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml" >"$cas_output"
/usr/bin/grep -Fx 'cas_state=already-active' "$cas_output" >/dev/null ||
  fail "CAS already-active state was not reported"

expect_failure "CAS conflict: current feed is neither expected nor candidate" \
  "$VERIFY_SCRIPT" --mode cas \
  --current-feed "$unknown_feed" \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml"

"$VERIFY_SCRIPT" --mode cas --current-absent --expected-previous-absent \
  --candidate-feed "$inputs_dir/production/appcast.xml" >"$cas_output"
/usr/bin/grep -Fx 'cas_state=ready-bootstrap' "$cas_output" >/dev/null ||
  fail "CAS bootstrap state was not reported"

expect_failure "CAS conflict: expected an absent current feed" \
  "$VERIFY_SCRIPT" --mode cas \
  --current-feed "$inputs_dir/previous-appcast.xml" \
  --expected-previous-absent \
  --candidate-feed "$inputs_dir/production/appcast.xml"

expect_failure "CAS conflict: current feed is absent" \
  "$VERIFY_SCRIPT" --mode cas --current-absent \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml"

mutable_sparkle_source="$fixture_root/mutable-Sparkle"
/usr/bin/git clone --quiet --no-local "$SPARKLE_SOURCE" "$mutable_sparkle_source"
/usr/bin/git -c advice.detachedHead=false -C "$mutable_sparkle_source" checkout --quiet --detach \
  b6496a74a087257ef5e6da1c5b29a447a60f5bd7
mutable_sparkle_source_path="$mutable_sparkle_source/$sparkle_source_file"
mutable_sparkle_injected_header="$mutable_sparkle_source/Vendor/ed25519-sparkle/src/stdlib.h"

printf '#include_next <stdlib.h>\n' >"$mutable_sparkle_injected_header"
expect_failure "Sparkle source checkout is dirty" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/bin/rm -f "$mutable_sparkle_injected_header"

/bin/cp "$mutable_sparkle_source_path" "$fixture_root/original-fe.c"
printf '\n' >>"$mutable_sparkle_source_path"
expect_failure "Sparkle source checkout is dirty" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/bin/cp "$fixture_root/original-fe.c" "$mutable_sparkle_source_path"

/usr/bin/git -C "$mutable_sparkle_source" update-index --assume-unchanged "$sparkle_source_file"
expect_failure "Sparkle source checkout has hidden index flags" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/usr/bin/git -C "$mutable_sparkle_source" update-index --no-assume-unchanged "$sparkle_source_file"

/usr/bin/git -C "$mutable_sparkle_source" update-index --skip-worktree "$sparkle_source_file"
expect_failure "Sparkle source checkout has hidden index flags" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/usr/bin/git -C "$mutable_sparkle_source" update-index --no-skip-worktree "$sparkle_source_file"

echo "update feed fixtures passed"
