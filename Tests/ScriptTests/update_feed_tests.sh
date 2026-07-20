#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE_SCRIPT="$ROOT_DIR/script/prepare_appcast_inputs.sh"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_update_artifacts.sh"
QUALIFY_SCRIPT="$ROOT_DIR/script/qualify_update.sh"
SPARKLE_SOURCE="$ROOT_DIR/.build/checkouts/Sparkle"
SPARKLE_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"
CI_WORKFLOW="$WORKFLOW_DIR/ci.yml"
CODEOWNERS_FILE="$ROOT_DIR/.github/CODEOWNERS"

[[ -x "$PREPARE_SCRIPT" ]] || {
  echo "prepare_appcast_inputs.sh does not exist" >&2
  exit 1
}
[[ -x "$VERIFY_SCRIPT" ]] || {
  echo "verify_update_artifacts.sh does not exist" >&2
  exit 1
}
[[ -x "$QUALIFY_SCRIPT" ]] || {
  echo "qualify_update.sh does not exist" >&2
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

validate_workflow_policy() {
  /usr/bin/python3 - "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" <<'PYTHON'
import pathlib
import re
import sys

workflow_dir = pathlib.Path(sys.argv[1])
ci_path = pathlib.Path(sys.argv[2])
codeowners_path = pathlib.Path(sys.argv[3])


def reject(message: str) -> None:
    raise SystemExit(message)


if not ci_path.is_file():
    reject("CI workflow does not exist")

workflows = sorted(workflow_dir.glob("*.yml"))
if not workflows:
    reject("no workflows found")

for workflow_path in workflows:
    text = workflow_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    for line in lines:
        match = re.match(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", line)
        if not match:
            continue
        action = match.group(1).strip("'\"")
        if action.startswith("./"):
            continue
        if not re.search(r"@[0-9a-fA-F]{40}$", action):
            reject(f"{workflow_path.name} contains an unpinned action: {action}")

    top_permissions = []
    in_top_permissions = False
    current_job = None
    in_jobs = False
    has_concurrency = False
    has_cancellation = False
    in_top_concurrency = False
    for line in lines:
        concurrency_match = re.match(r"^concurrency:\s*(.*)$", line)
        if concurrency_match:
            has_concurrency = True
            in_top_concurrency = not concurrency_match.group(1).strip().startswith("#")
            if concurrency_match.group(1).strip():
                in_top_concurrency = False
            continue
        if in_top_concurrency:
            if line and not line[0].isspace() and not line.lstrip().startswith("#"):
                in_top_concurrency = False
            elif re.match(r"^\s+cancel-in-progress:\s*true\s*(?:#.*)?$", line):
                has_cancellation = True

        permissions_match = re.match(r"^permissions:\s*(.*)$", line)
        if permissions_match:
            permissions_value = permissions_match.group(1).split("#", 1)[0].strip()
            if permissions_value and ("write" in permissions_value or permissions_value == "write-all"):
                top_permissions.append(line)
            in_top_permissions = not permissions_value
            continue
        if in_top_permissions:
            if line and not line[0].isspace() and not line.lstrip().startswith("#"):
                in_top_permissions = False
            elif re.match(r"^\s+contents:\s*write\s*(?:#.*)?$", line):
                top_permissions.append(line)

        if re.match(r"^jobs:\s*(?:#.*)?$", line):
            in_jobs = True
            current_job = None
            continue
        if in_jobs:
            job_match = re.match(r"^  ([A-Za-z_][A-Za-z0-9_-]*):\s*(?:#.*)?$", line)
            if job_match:
                current_job = job_match.group(1)
            elif line and not line[0].isspace() and not line.lstrip().startswith("#"):
                in_jobs = False
                current_job = None
        if re.search(r"\$\{\{\s*secrets\.", line) and current_job != "sign-candidate":
            reject(f"{workflow_path.name} references a secret outside sign-candidate")

    if top_permissions:
        reject(f"{workflow_path.name} grants global contents: write")
    if not has_concurrency or not has_cancellation:
        reject(f"{workflow_path.name} lacks cancellable concurrency")

ci = ci_path.read_text(encoding="utf-8")
required_ci_snippets = (
    "permissions:\n  contents: read",
    "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
    "swift test",
    "bash Tests/ScriptTests/release_common_tests.sh",
    "bash Tests/ScriptTests/package_verification_tests.sh",
    "bash Tests/ScriptTests/update_feed_tests.sh",
    "find script -name '*.sh' -print0 | xargs -0 -n1 bash -n",
    './script/package_app.sh --output dist/ci --configuration release --architectures "$(uname -m)" --updates-enabled false',
    "https://github.com/rhysd/actionlint/releases/download/v1.7.12/",
    "actionlint_1.7.12_darwin_arm64.tar.gz",
    "actionlint_1.7.12_darwin_amd64.tar.gz",
    "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
    "5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644",
)
for snippet in required_ci_snippets:
    if snippet not in ci:
        reject(f"ci.yml lacks required content: {snippet}")

checksum_index = ci.find("shasum -a 256 -c -")
extract_index = ci.find("tar -xzf")
if checksum_index < 0 or extract_index < 0 or checksum_index > extract_index:
    reject("ci.yml must verify actionlint before extraction")

if not codeowners_path.is_file():
    reject("CODEOWNERS does not exist")
expected_owners = (
    "/.github/workflows/ @tangwz",
    "/script/ @tangwz",
    "/config/update.env @tangwz",
    "/appcast.xml @tangwz",
)
actual_owners = tuple(
    line.strip()
    for line in codeowners_path.read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
)
if actual_owners != expected_owners:
    reject("CODEOWNERS does not protect update supply-chain files")
PYTHON
}

validate_workflow_policy

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
  local channel_title="${10:-CodexRadar}"
  local content_path="$output_path.content" feed_signature content_length

  {
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
    printf '<rss xmlns:sparkle="%s" version="2.0">\n' "$SPARKLE_NAMESPACE"
    printf '<channel><title>%s</title><item>\n' "$channel_title"
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

qualification_bundle="$fixture_root/qualification-bundle"
/usr/bin/ditto "$inputs_dir" "$qualification_bundle"
/bin/mkdir -p "$qualification_bundle/bin" \
  "$qualification_bundle/Frameworks/Sparkle.framework/Versions/A/Resources"
printf '#!/usr/bin/env bash\n[[ -z "${QUALIFY_TEST_CLI_LOG:-}" ]] || printf "cli\\n" >>"$QUALIFY_TEST_CLI_LOG"\nexit 0\n' >"$qualification_bundle/bin/sparkle"
/bin/chmod 755 "$qualification_bundle/bin/sparkle"
write_info_plist \
  "$qualification_bundle/Frameworks/Sparkle.framework/Versions/A/Resources/Info.plist" \
  2.9.4 1 14.0 "$PUBLIC_KEY"
/bin/ln -s A "$qualification_bundle/Frameworks/Sparkle.framework/Versions/Current"
/bin/ln -s Versions/Current/Resources "$qualification_bundle/Frameworks/Sparkle.framework/Resources"

previous_app="$fixture_root/previous-app/CodexRadar.app"
write_info_plist "$previous_app/Contents/Info.plist" 0.1.0 1 14.0 "$PUBLIC_KEY"
/bin/mkdir -p "$previous_app/Contents/MacOS"
printf '#!/usr/bin/env bash\nexit 0\n' >"$previous_app/Contents/MacOS/CodexRadar"
/bin/chmod 755 "$previous_app/Contents/MacOS/CodexRadar"

app_tree_manifest() {
  /usr/bin/python3 - "$1" <<'PYTHON'
import hashlib, os, stat, sys

root = os.path.realpath(sys.argv[1])
records = []
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    names = sorted(dirs + files, key=os.fsencode)
    dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(base, name))]
    for name in names:
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root)
        mode = stat.S_IMODE(os.lstat(path).st_mode)
        if os.path.islink(path):
            records.append((rel, 'L', str(mode), os.readlink(path)))
        elif os.path.isfile(path):
            digest = hashlib.sha256()
            with open(path, 'rb') as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                    digest.update(chunk)
            records.append((rel, 'F', str(mode), digest.hexdigest()))
        elif os.path.isdir(path):
            records.append((rel, 'D', str(mode), ''))
        else:
            raise SystemExit('unsupported file type: ' + rel)
print(hashlib.sha256(repr(sorted(records)).encode()).hexdigest())
PYTHON
}

previous_tree_manifest="$(app_tree_manifest "$previous_app")"

qualification_python="$fixture_root/qualification-python"
qualification_runner="$fixture_root/qualification-runner"
qualification_python_log="$fixture_root/qualification-python.log"
qualification_runner_arguments="$fixture_root/qualification-runner.arguments"
qualification_cli_log="$fixture_root/qualification-cli.log"
qualification_server_pid="$fixture_root/qualification-server.pid"
qualification_harness_pid="$fixture_root/qualification-harness.pid"
cat >"$qualification_python" <<'PYTHON_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf 'python\n' >>"$QUALIFY_TEST_PYTHON_LOG"
if [[ "${QUALIFY_TEST_PYTHON_MODE:-}" == server-exits && "$#" -eq 4 && "$1" == - && "$4" == *.port ]]; then
  printf '49152\n' >"$4"
  exit 0
fi
exec /usr/bin/python3 "$@"
PYTHON_WRAPPER
cat >"$qualification_runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"$QUALIFY_TEST_RUNNER_ARGUMENTS"
[[ "$#" -eq 9 ]]
[[ "$(/usr/bin/basename "$1")" == sparkle-cli ]]
[[ "$1" != "$QUALIFY_TEST_BUNDLE_CLI" ]]
[[ "$3" == --application ]]
[[ "$4" == "$2" ]]
[[ "$5" == --check-immediately ]]
[[ "$6" == --feed-url ]]
[[ "$7" =~ ^http://127\.0\.0\.1:[1-9][0-9]*/appcast\.xml$ ]]
[[ "$8" == --interactive ]]
[[ "$9" == --verbose ]]
/usr/bin/curl --fail --silent "$7" >/dev/null

case "${QUALIFY_TEST_RUNNER_MODE:-success}" in
  success)
    /bin/cp "$QUALIFY_TEST_CANDIDATE_INFO" "$2/Contents/Info.plist"
    ;;
  mutate-source)
    printf 'mutated source bundle\n' >"$QUALIFY_TEST_SOURCE_BUNDLE/qualification/appcast.xml"
    /usr/bin/curl --fail --silent "$7" | /usr/bin/cmp -s - "$QUALIFY_TEST_EXPECTED_FEED"
    /bin/cp "$QUALIFY_TEST_CANDIDATE_INFO" "$2/Contents/Info.plist"
    ;;
  install-info)
    /bin/cp "$QUALIFY_TEST_INSTALLED_INFO" "$2/Contents/Info.plist"
    ;;
  wait-for-signal)
    : >"$QUALIFY_TEST_RUNNER_READY"
    while [[ ! -e "$QUALIFY_TEST_RUNNER_RELEASE" ]]; do /bin/sleep .05; done
    ;;
  failure)
    exit 17
    ;;
  signal-int)
    /bin/kill -INT "$(<"$QUALIFY_TEST_HARNESS_PID_FILE")"
    exit 0
    ;;
  signal-term)
    /bin/kill -TERM "$(<"$QUALIFY_TEST_HARNESS_PID_FILE")"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
RUNNER
qualification_ditto="$fixture_root/qualification-ditto"
cat >"$qualification_ditto" <<'DITTO'
#!/usr/bin/env bash
set -euo pipefail

case "${QUALIFY_TEST_DITTO_MODE:-copy}" in
  copy)
    ;;
  mutate)
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 99' "$1/Contents/Info.plist"
    ;;
  replace)
    replacement="$1.replacement"
    original="$1.original"
    /usr/bin/ditto "$1" "$replacement"
    /bin/mv "$1" "$original"
    /bin/mv "$replacement" "$1"
    ;;
  *)
    exit 2
    ;;
esac

exec /usr/bin/ditto "$@"
DITTO
/bin/chmod 755 "$qualification_python" "$qualification_runner" "$qualification_ditto"

qualification_fetch="$fixture_root/qualification-fetch"
qualification_harness="$fixture_root/qualify-update-harness.sh"
qualification_tools_root="$fixture_root/qualification-tools"
qualification_tools_archive="$fixture_root/Sparkle-2.9.4-test.tar.xz"
/bin/mkdir -p "$qualification_tools_root/bin"
printf 'fixture\n' >"$qualification_tools_root/bin/placeholder"
/usr/bin/tar -cJf "$qualification_tools_archive" -C "$qualification_tools_root" .
qualification_tools_sha="$(/usr/bin/shasum -a 256 "$qualification_tools_archive" | /usr/bin/awk '{print $1}')"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf '[[ "$1" == "https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml" ]]\n'
  printf '/bin/cp "$QUALIFY_TEST_CURRENT_FEED" "$2"\n'
} >"$qualification_fetch"
/bin/chmod 755 "$qualification_fetch"
/usr/bin/sed \
  -e "s/^EXPECTED_TOOLS_SHA256=.*/EXPECTED_TOOLS_SHA256=\"$qualification_tools_sha\"/" \
  -e 's/^TEST_HARNESS=false/TEST_HARNESS=true/' \
  "$QUALIFY_SCRIPT" >"$qualification_harness"
/bin/chmod 755 "$qualification_harness"

run_qualification() {
  local bundle_path="${1:-$qualification_bundle}"
  local app_path="${2:-$previous_app}"
  local current_feed="${3:-$previous_dir/appcast.xml}"

  env \
    QUALIFY_PYTHON_EXECUTABLE="$qualification_python" \
    QUALIFY_TEST_CLI="$qualification_bundle/bin/sparkle" \
    QUALIFY_RUNNER="$qualification_runner" \
    QUALIFY_FETCH_EXECUTABLE="$qualification_fetch" \
    QUALIFY_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
    QUALIFY_VERSION_CONFIG="$candidate_dir/version.env" \
    QUALIFY_UPDATE_CONFIG="$candidate_dir/update.env" \
    QUALIFY_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
    QUALIFY_TEST_PYTHON_LOG="$qualification_python_log" \
    QUALIFY_TEST_RUNNER_ARGUMENTS="$qualification_runner_arguments" \
    QUALIFY_TEST_BUNDLE_CLI="$qualification_bundle/bin/sparkle" \
    QUALIFY_TEST_CANDIDATE_INFO="$candidate_info" \
    QUALIFY_TEST_CURRENT_FEED="$current_feed" \
    QUALIFY_TEST_SOURCE_BUNDLE="$bundle_path" \
    QUALIFY_TEST_EXPECTED_FEED="$qualification_expected_feed" \
    QUALIFY_TEST_DITTO="$qualification_ditto" \
    QUALIFY_TEST_SERVER_PID_FILE="$qualification_server_pid" \
    QUALIFY_TEST_HARNESS_PID_FILE="$qualification_harness_pid" \
    QUALIFY_TEST_DITTO_MODE="${QUALIFY_TEST_DITTO_MODE:-copy}" \
    QUALIFY_TEST_PYTHON_MODE="${QUALIFY_TEST_PYTHON_MODE:-}" \
    QUALIFY_TEST_RUNNER_MODE="${QUALIFY_TEST_RUNNER_MODE:-success}" \
    QUALIFY_TEST_INSTALLED_INFO="${QUALIFY_TEST_INSTALLED_INFO:-}" \
    QUALIFY_TEST_RUNNER_READY="${QUALIFY_TEST_RUNNER_READY:-}" \
    QUALIFY_TEST_RUNNER_RELEASE="${QUALIFY_TEST_RUNNER_RELEASE:-}" \
    "$qualification_harness" --bundle "$bundle_path" --previous-app "$app_path" \
    --tools-archive "$qualification_tools_archive"
}

run_qualification_without_runner() {
  local bundle_path="$1" app_path="$2" current_feed="$3"

  env \
    QUALIFY_PYTHON_EXECUTABLE="$qualification_python" \
    QUALIFY_TEST_CLI="$qualification_bundle/bin/sparkle" \
    QUALIFY_RUNNER="" \
    QUALIFY_FETCH_EXECUTABLE="$qualification_fetch" \
    QUALIFY_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
    QUALIFY_VERSION_CONFIG="$candidate_dir/version.env" \
    QUALIFY_UPDATE_CONFIG="$candidate_dir/update.env" \
    QUALIFY_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
    QUALIFY_TEST_PYTHON_LOG="$qualification_python_log" \
    QUALIFY_TEST_CLI_LOG="$qualification_cli_log" \
    QUALIFY_TEST_CURRENT_FEED="$current_feed" \
    QUALIFY_TEST_DITTO="$qualification_ditto" \
    QUALIFY_TEST_SERVER_PID_FILE="$qualification_server_pid" \
    QUALIFY_TEST_HARNESS_PID_FILE="$qualification_harness_pid" \
    QUALIFY_TEST_DITTO_MODE="${QUALIFY_TEST_DITTO_MODE:-copy}" \
    QUALIFY_TEST_PYTHON_MODE="${QUALIFY_TEST_PYTHON_MODE:-}" \
    "$qualification_harness" --bundle "$bundle_path" --previous-app "$app_path" \
    --tools-archive "$qualification_tools_archive"
}

assert_preflight_did_not_run_update() {
  [[ ! -s "$qualification_runner_arguments" ]] || fail "qualification invoked runner before rejecting input"
  [[ ! -s "$qualification_cli_log" ]] || fail "qualification invoked CLI before rejecting input"
}

expect_preflight_failure() {
  local expected_message="$1"
  shift
  : >"$qualification_runner_arguments"
  : >"$qualification_cli_log"
  : >"$qualification_python_log"
  expect_failure "$expected_message" run_qualification_without_runner "$@"
  assert_preflight_did_not_run_update
}

expect_preflight_rejection() {
  local bundle_path="$1" app_path="$2" current_feed="$3"
  local output_path="$fixture_root/preflight-output"

  : >"$qualification_runner_arguments"
  : >"$qualification_cli_log"
  : >"$qualification_python_log"
  if run_qualification_without_runner "$bundle_path" "$app_path" "$current_feed" >"$output_path" 2>&1; then
    /bin/cat "$output_path" >&2
    fail "qualification accepted invalid preflight input"
  fi
  assert_preflight_did_not_run_update
}

expect_installed_rejection() {
  local key="$1" installed_info="$2"
  local output_path="$fixture_root/installed-output"

  : >"$qualification_runner_arguments"
  if QUALIFY_TEST_RUNNER_MODE=install-info QUALIFY_TEST_INSTALLED_INFO="$installed_info" \
    run_qualification >"$output_path" 2>&1; then
    /bin/cat "$output_path" >&2
    fail "qualification accepted an installed application with invalid $key"
  fi
  /usr/bin/grep -F "installed application $key does not match qualification bundle" "$output_path" >/dev/null || {
    /bin/cat "$output_path" >&2
    fail "qualification did not reject invalid installed $key"
  }
  [[ -s "$qualification_runner_arguments" ]] || fail "qualification did not run the fixture installer"
}

qualification_expected_feed="$fixture_root/expected-qualification-appcast.xml"
/bin/cp "$qualification_bundle/qualification/appcast.xml" "$qualification_expected_feed"

: >"$qualification_python_log"
run_qualification
[[ -s "$qualification_runner_arguments" ]] || fail "qualification did not invoke runner"
[[ ! -e "$(/usr/bin/dirname "$(/usr/bin/sed -n '2p' "$qualification_runner_arguments")")" ]] ||
  fail "qualification did not clean copied application"
[[ "$previous_tree_manifest" == "$(app_tree_manifest "$previous_app")" ]] ||
  fail "qualification changed original previous application"

replaced_source_app="$fixture_root/replaced-source/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$replaced_source_app"
replaced_source_tree="$(app_tree_manifest "$replaced_source_app")"
QUALIFY_TEST_DITTO_MODE=replace expect_preflight_failure "previous application directory changed while being copied" \
  "$qualification_bundle" "$replaced_source_app" "$previous_dir/appcast.xml"
[[ "$replaced_source_tree" == "$(app_tree_manifest "$replaced_source_app")" ]] ||
  fail "source replacement did not preserve the original whole-tree fixture"

mutated_source_app="$fixture_root/mutated-source/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$mutated_source_app"
mutated_source_tree="$(app_tree_manifest "$mutated_source_app")"
QUALIFY_TEST_DITTO_MODE=mutate expect_preflight_failure "previous application changed while being copied" \
  "$qualification_bundle" "$mutated_source_app" "$previous_dir/appcast.xml"
[[ "$mutated_source_tree" != "$(app_tree_manifest "$mutated_source_app")" ]] ||
  fail "copy mutation fixture did not alter the source application"

current_feed_mismatch="$fixture_root/current-production-feed-mismatch.xml"
make_feed "$current_feed_mismatch" 0.1.0 1 14.0 "$previous_url" 123 "$archive_signature" \
  '' false CodexRadarCurrent
expect_preflight_failure "bundled previous Production Feed is stale" \
  "$qualification_bundle" "$previous_app" "$current_feed_mismatch"

escaping_contents_app="$fixture_root/escaping-contents/CodexRadar.app"
escaping_target="$fixture_root/escaping-target"
/usr/bin/ditto "$previous_app" "$escaping_contents_app"
/bin/mkdir -p "$escaping_target"
/bin/mv "$escaping_contents_app/Contents" "$escaping_contents_app/RealContents"
/bin/ln -s "$escaping_target" "$escaping_contents_app/Contents"
expect_preflight_failure "application contains an unresolved or escaping symlink: Contents" \
  "$qualification_bundle" "$escaping_contents_app" "$previous_dir/appcast.xml"

internal_symlink_app="$fixture_root/internal-symlink/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$internal_symlink_app"
/bin/ln -s MacOS "$internal_symlink_app/Contents/InternalExecutableDirectory"
internal_symlink_tree="$(app_tree_manifest "$internal_symlink_app")"
run_qualification "$qualification_bundle" "$internal_symlink_app" "$previous_dir/appcast.xml"
[[ "$internal_symlink_tree" == "$(app_tree_manifest "$internal_symlink_app")" ]] ||
  fail "qualification changed the internal-symlink source application"

snapshot_mutation_bundle="$fixture_root/snapshot-mutation-bundle"
/usr/bin/ditto "$qualification_bundle" "$snapshot_mutation_bundle"
QUALIFY_TEST_RUNNER_MODE=mutate-source run_qualification \
  "$snapshot_mutation_bundle" "$previous_app" "$previous_dir/appcast.xml"
[[ ! -s "$qualification_runner_arguments" ]] && fail "qualification did not run the snapshot mutation fixture"
/usr/bin/cmp -s "$snapshot_mutation_bundle/qualification/appcast.xml" "$qualification_expected_feed" &&
  fail "source bundle mutation did not change the source feed"

QUALIFY_TEST_PYTHON_MODE=server-exits expect_preflight_failure \
  "qualification HTTP server exited after publishing its port" \
  "$qualification_bundle" "$previous_app" "$previous_dir/appcast.xml"

for key in CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey; do
  invalid_installed_info="$fixture_root/invalid-installed-$key.plist"
  /bin/cp "$candidate_info" "$invalid_installed_info"
  /usr/libexec/PlistBuddy -c "Set :$key invalid" "$invalid_installed_info"
  expect_installed_rejection "$key" "$invalid_installed_info"
done
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
  invalid_installed_info="$fixture_root/invalid-installed-$key.plist"
  /bin/cp "$candidate_info" "$invalid_installed_info"
  /usr/libexec/PlistBuddy -c "Set :$key false" "$invalid_installed_info"
  expect_installed_rejection "$key" "$invalid_installed_info"
done

for key in CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey; do
  invalid_bundle="$fixture_root/invalid-bundle-$key"
  /usr/bin/ditto "$qualification_bundle" "$invalid_bundle"
  /usr/libexec/PlistBuddy -c "Set :$key invalid" "$invalid_bundle/Info.plist"
  expect_preflight_rejection "$invalid_bundle" "$previous_app" "$previous_dir/appcast.xml"
done
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
  invalid_bundle="$fixture_root/invalid-bundle-$key"
  /usr/bin/ditto "$qualification_bundle" "$invalid_bundle"
  /usr/libexec/PlistBuddy -c "Set :$key false" "$invalid_bundle/Info.plist"
  expect_preflight_rejection "$invalid_bundle" "$previous_app" "$previous_dir/appcast.xml"
done

bad_manifest_bundle="$fixture_root/bad-manifest-qualification-bundle"
/usr/bin/ditto "$qualification_bundle" "$bad_manifest_bundle"
printf 'unexpected=true\n' >>"$bad_manifest_bundle/manifest"
: >"$qualification_python_log"
if env \
  QUALIFY_PYTHON_EXECUTABLE="$qualification_python" \
  QUALIFY_TEST_CLI="$bad_manifest_bundle/bin/sparkle" \
  QUALIFY_RUNNER="$qualification_runner" \
  QUALIFY_FETCH_EXECUTABLE="$qualification_fetch" \
  QUALIFY_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
  QUALIFY_VERSION_CONFIG="$candidate_dir/version.env" \
  QUALIFY_UPDATE_CONFIG="$candidate_dir/update.env" \
  QUALIFY_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
  QUALIFY_TEST_PYTHON_LOG="$qualification_python_log" \
  QUALIFY_TEST_RUNNER_ARGUMENTS="$qualification_runner_arguments" \
  QUALIFY_TEST_BUNDLE_CLI="$bad_manifest_bundle/bin/sparkle" \
  QUALIFY_TEST_CANDIDATE_INFO="$candidate_info" \
  QUALIFY_TEST_CURRENT_FEED="$previous_dir/appcast.xml" \
  "$qualification_harness" --bundle "$bad_manifest_bundle" --previous-app "$previous_app" \
  --tools-archive "$qualification_tools_archive"; then
  fail "qualification accepted an invalid manifest"
fi
[[ ! -s "$qualification_python_log" ]] || fail "qualification started a server before manifest validation"

forged_bundle_cli="$qualification_bundle/bin/sparkle"
printf '#!/usr/bin/env bash\necho forged\n' >"$forged_bundle_cli"
/bin/chmod 755 "$forged_bundle_cli"
run_qualification
[[ "$(/usr/bin/sed -n '1p' "$qualification_runner_arguments")" != "$forged_bundle_cli" ]] ||
  fail "qualification executed a forged bundle CLI"

: >"$qualification_python_log"
if QUALIFY_TEST_RUNNER_MODE=failure run_qualification; then
  fail "qualification accepted a failed Sparkle command"
fi
[[ ! -e "$(/usr/bin/dirname "$(/usr/bin/sed -n '2p' "$qualification_runner_arguments")")" ]] ||
  fail "qualification did not clean copied application after runner failure"

for signal_mode in signal-int signal-term; do
  : >"$qualification_server_pid"
  : >"$qualification_python_log"
  if QUALIFY_TEST_RUNNER_MODE="$signal_mode" run_qualification; then
    fail "qualification accepted $signal_mode"
  else
    signal_status="$?"
  fi
  [[ "$signal_status" == "$([[ "$signal_mode" == signal-int ]] && echo 130 || echo 143)" ]] ||
    fail "qualification returned $signal_status after $signal_mode"
  [[ -s "$qualification_server_pid" ]] || fail "qualification did not record server PID for $signal_mode"
  server_pid="$(<"$qualification_server_pid")"
  /bin/kill -0 "$server_pid" 2>/dev/null && fail "qualification left server $server_pid alive after $signal_mode"
  [[ ! -e "$(/usr/bin/dirname "$(/usr/bin/sed -n '2p' "$qualification_runner_arguments")")" ]] ||
    fail "qualification did not clean copied application after $signal_mode"
done

echo "update feed fixtures passed"
