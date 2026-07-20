#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_SPARKLE_REVISION="b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
EXPECTED_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"
SPARKLE_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"

usage() {
  cat >&2 <<EOF
usage:
  $0 --mode previous --feed PATH --version-config PATH --update-config PATH --sparkle-source PATH
  $0 --mode artifacts --inputs PATH --archive PATH --manifest PATH --final-info-plist PATH --version-config PATH --update-config PATH --sparkle-source PATH
  $0 --mode cas (--current-feed PATH|--current-absent) (--expected-previous-feed PATH|--expected-previous-absent) --candidate-feed PATH
EOF
  return 2
}

assert_real_file() {
  local path="$1" description="$2"

  [[ -f "$path" && ! -L "$path" ]] || die "$description must be a real file" || return 1
}

assert_real_directory() {
  local path="$1" description="$2"

  [[ -d "$path" && ! -L "$path" ]] || die "$description must be a real directory" || return 1
}

load_update_config() {
  local config_path="$1" line key value
  local seen_version=false seen_key=false seen_url=false decoded_size canonical_key

  SPARKLE_VERSION=""
  SPARKLE_PUBLIC_ED_KEY=""
  PRODUCTION_FEED_URL=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || die "invalid update config line" || return 1
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      SPARKLE_VERSION)
        [[ "$seen_version" == false ]] || die "duplicate SPARKLE_VERSION" || return 1
        seen_version=true
        SPARKLE_VERSION="$value"
        ;;
      SPARKLE_PUBLIC_ED_KEY)
        [[ "$seen_key" == false ]] || die "duplicate SPARKLE_PUBLIC_ED_KEY" || return 1
        seen_key=true
        SPARKLE_PUBLIC_ED_KEY="$value"
        ;;
      PRODUCTION_FEED_URL)
        [[ "$seen_url" == false ]] || die "duplicate PRODUCTION_FEED_URL" || return 1
        seen_url=true
        PRODUCTION_FEED_URL="$value"
        ;;
      *) die "unknown update key: $key" || return 1 ;;
    esac
  done <"$config_path"

  [[ "$SPARKLE_VERSION" == "$EXPECTED_SPARKLE_VERSION" ]] ||
    die "SPARKLE_VERSION must equal $EXPECTED_SPARKLE_VERSION" || return 1
  [[ "$PRODUCTION_FEED_URL" == "$EXPECTED_FEED_URL" ]] ||
    die "PRODUCTION_FEED_URL must equal $EXPECTED_FEED_URL" || return 1
  decoded_size="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D 2>/dev/null | \
    /usr/bin/wc -c | /usr/bin/tr -d ' ')" || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  [[ "$decoded_size" == 32 ]] || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  canonical_key="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D 2>/dev/null | \
    /usr/bin/base64 | /usr/bin/tr -d '\n')" || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  [[ "$canonical_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] ||
    die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
}

is_decimal() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

decimal_is_greater() {
  local left="$1" right="$2"

  is_decimal "$left" && is_decimal "$right" || return 1
  if [[ "${#left}" -ne "${#right}" ]]; then
    [[ "${#left}" -gt "${#right}" ]]
  else
    [[ "$left" > "$right" ]]
  fi
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

assert_plist_value() {
  local plist_path="$1" key="$2" expected="$3" message="$4" actual

  actual="$(plist_value "$plist_path" "$key" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || die "$message" || return 1
}

load_manifest() {
  local manifest_path="$1" line key value
  local seen_archive=false seen_version=false seen_build=false seen_length=false
  local seen_sha=false seen_mode=false seen_trust=false

  MANIFEST_ARCHIVE_NAME=""
  MANIFEST_VERSION=""
  MANIFEST_BUILD=""
  MANIFEST_BYTE_LENGTH=""
  MANIFEST_SHA256=""
  MANIFEST_SIGNING_MODE=""
  MANIFEST_DISTRIBUTION_TRUST=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die "invalid manifest line" || return 1
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      archive_name)
        [[ "$seen_archive" == false ]] || die "duplicate archive_name" || return 1
        seen_archive=true
        MANIFEST_ARCHIVE_NAME="$value"
        ;;
      version)
        [[ "$seen_version" == false ]] || die "duplicate version" || return 1
        seen_version=true
        MANIFEST_VERSION="$value"
        ;;
      build)
        [[ "$seen_build" == false ]] || die "duplicate build" || return 1
        seen_build=true
        MANIFEST_BUILD="$value"
        ;;
      byte_length)
        [[ "$seen_length" == false ]] || die "duplicate byte_length" || return 1
        seen_length=true
        MANIFEST_BYTE_LENGTH="$value"
        ;;
      sha256)
        [[ "$seen_sha" == false ]] || die "duplicate sha256" || return 1
        seen_sha=true
        MANIFEST_SHA256="$value"
        ;;
      signing_mode)
        [[ "$seen_mode" == false ]] || die "duplicate signing_mode" || return 1
        seen_mode=true
        MANIFEST_SIGNING_MODE="$value"
        ;;
      distribution_trust)
        [[ "$seen_trust" == false ]] || die "duplicate distribution_trust" || return 1
        seen_trust=true
        MANIFEST_DISTRIBUTION_TRUST="$value"
        ;;
      *) die "unknown manifest key: $key" || return 1 ;;
    esac
  done <"$manifest_path"

  [[ "$seen_archive" == true && "$seen_version" == true && "$seen_build" == true && \
    "$seen_length" == true && "$seen_sha" == true && "$seen_mode" == true && \
    "$seen_trust" == true ]] || die "manifest is missing required keys" || return 1
  [[ "$MANIFEST_ARCHIVE_NAME" =~ ^CodexRadar-v[0-9]+\.[0-9]+\.[0-9]+-macos-universal\.zip$ ]] ||
    die "invalid manifest archive_name" || return 1
  [[ "$MANIFEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "invalid manifest version" || return 1
  [[ "$MANIFEST_BUILD" =~ ^[1-9][0-9]*$ ]] || die "invalid manifest build" || return 1
  is_decimal "$MANIFEST_BYTE_LENGTH" || die "invalid manifest byte_length" || return 1
  [[ "$MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid manifest sha256" || return 1
  case "$MANIFEST_SIGNING_MODE:$MANIFEST_DISTRIBUTION_TRUST" in
    adhoc:locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted | \
      developer-id:developer-id-notarized) ;;
    *) die "invalid manifest signing trust" || return 1 ;;
  esac
}

work_dir=""
cleanup() {
  if [[ -n "$work_dir" && -d "$work_dir" && ! -L "$work_dir" ]]; then
    /bin/rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

compile_sparkle_verifier() {
  local sparkle_source="$1" source_dir head path index_entry expected_blob written_blob
  local checkout_status compiler_path sdk_path

  assert_real_directory "$sparkle_source" "Sparkle source"
  [[ "$(git_in_sparkle_checkout "$sparkle_source" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] ||
    die "Sparkle source must be a Git checkout" || return 1
  head="$(git_in_sparkle_checkout "$sparkle_source" rev-parse HEAD 2>/dev/null)" ||
    die "Sparkle source must be a Git checkout" || return 1
  [[ "$head" == "$EXPECTED_SPARKLE_REVISION" ]] ||
    die "Sparkle source revision must equal $EXPECTED_SPARKLE_REVISION" || return 1
  git_in_sparkle_checkout "$sparkle_source" cat-file -e "$EXPECTED_SPARKLE_REVISION^{commit}" ||
    die "Sparkle source revision is unavailable" || return 1
  checkout_status="$(git_in_sparkle_checkout "$sparkle_source" status --porcelain=v1 \
    --untracked-files=all --ignored=no)" ||
    die "Sparkle source checkout status is unavailable" || return 1
  [[ -z "$checkout_status" ]] || die "Sparkle source checkout is dirty" || return 1
  for path in ed25519.h fixedint.h fe.h fe.c ge.h ge.c precomp_data.h sc.h sc.c \
    sha512.h sha512.c verify.c; do
    index_entry="$(git_in_sparkle_checkout "$sparkle_source" ls-files -v -- \
      "Vendor/ed25519-sparkle/src/$path")" ||
      die "Sparkle Ed25519 source file is unavailable" || return 1
    [[ "$index_entry" == "H Vendor/ed25519-sparkle/src/$path" ]] ||
      die "Sparkle source checkout has hidden index flags" || return 1
  done

  source_dir="$work_dir/sparkle-ed25519"
  /bin/mkdir -m 700 "$source_dir" || die "unable to create isolated Sparkle source" || return 1
  for path in ed25519.h fixedint.h fe.h fe.c ge.h ge.c precomp_data.h sc.h sc.c \
    sha512.h sha512.c verify.c; do
    expected_blob="$(git_in_sparkle_checkout "$sparkle_source" rev-parse \
      "$EXPECTED_SPARKLE_REVISION:Vendor/ed25519-sparkle/src/$path" 2>/dev/null)" ||
      die "Sparkle Ed25519 source file is unavailable" || return 1
    [[ "$expected_blob" =~ ^[0-9a-f]{40}$ ]] ||
      die "Sparkle Ed25519 source file has an invalid pinned blob" || return 1
    git_in_sparkle_checkout "$sparkle_source" cat-file blob \
      "$EXPECTED_SPARKLE_REVISION:Vendor/ed25519-sparkle/src/$path" >"$source_dir/$path" ||
      die "unable to export pinned Sparkle source" || return 1
    written_blob="$(git_in_sparkle_checkout "$sparkle_source" hash-object "$source_dir/$path")" ||
      die "unable to hash exported Sparkle source" || return 1
    [[ "$written_blob" == "$expected_blob" ]] ||
      die "exported Sparkle source does not match its pinned blob" || return 1
  done

  compiler_path="$(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
    /usr/bin/xcrun --sdk macosx --find clang 2>/dev/null)" ||
    die "unable to locate the C compiler" || return 1
  sdk_path="$(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
    /usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" ||
    die "unable to locate the macOS SDK" || return 1
  [[ -x "$compiler_path" && -d "$sdk_path" ]] ||
    die "unable to locate the C compiler or macOS SDK" || return 1

  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "$compiler_path" \
    -std=c11 -Wall -Wextra -Werror -DED25519_NO_SEED -isysroot "$sdk_path" \
    -iquote "$source_dir" \
    "$source_dir/fe.c" \
    "$source_dir/ge.c" \
    "$source_dir/sc.c" \
    "$source_dir/sha512.c" \
    "$source_dir/verify.c" \
    -x c - -o "$work_dir/verify-ed25519" <<'C'
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

int main(int argc, char **argv) {
    unsigned char *message;
    unsigned char *signature;
    unsigned char *public_key;
    size_t message_length;
    size_t signature_length;
    size_t public_key_length;
    int valid;

    if (argc != 4) {
        return 2;
    }
    message = read_file(argv[1], &message_length);
    signature = read_file(argv[2], &signature_length);
    public_key = read_file(argv[3], &public_key_length);
    if (message == NULL || signature == NULL || public_key == NULL ||
        signature_length != 64 || public_key_length != 32) {
        free(message);
        free(signature);
        free(public_key);
        return 1;
    }
    valid = ed25519_verify(signature, message, message_length, public_key);
    free(message);
    free(signature);
    free(public_key);
    return valid ? 0 : 1;
}
C
}

git_in_sparkle_checkout() {
  local sparkle_source="$1"
  shift

  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/git -C "$sparkle_source" "$@"
}

signature_counter=0
verify_ed25519_signature() {
  local data_path="$1" signature="$2" description="$3"
  local signature_path key_path canonical_signature

  signature_counter=$((signature_counter + 1))
  signature_path="$work_dir/signature-$signature_counter.raw"
  key_path="$work_dir/public-key-$signature_counter.raw"
  printf '%s' "$signature" | /usr/bin/base64 -D >"$signature_path" 2>/dev/null ||
    die "$description has an invalid Ed25519 signature" || return 1
  [[ "$(/usr/bin/stat -f '%z' "$signature_path")" == 64 ]] ||
    die "$description has an invalid Ed25519 signature" || return 1
  canonical_signature="$(/usr/bin/base64 <"$signature_path" | /usr/bin/tr -d '\n')"
  [[ "$canonical_signature" == "$signature" ]] ||
    die "$description has an invalid Ed25519 signature" || return 1
  printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D >"$key_path" 2>/dev/null ||
    die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  "$work_dir/verify-ed25519" "$data_path" "$signature_path" "$key_path" ||
    die "$description failed Ed25519 verification" || return 1
}

feed_counter=0
extract_and_verify_signed_feed() {
  local feed_path="$1" description="$2"
  local first_line signature_line length_line final_line signature length
  local content_path expected_block block_path total_length block_length

  assert_real_file "$feed_path" "$description"
  total_length="$(/usr/bin/stat -f '%z' "$feed_path")"
  [[ "$total_length" =~ ^[1-9][0-9]*$ && "$total_length" -le 8388608 ]] ||
    die "$description exceeds the signed feed size limit" || return 1
  first_line="$(/usr/bin/tail -n 4 "$feed_path" | /usr/bin/sed -n '1p')"
  signature_line="$(/usr/bin/tail -n 4 "$feed_path" | /usr/bin/sed -n '2p')"
  length_line="$(/usr/bin/tail -n 4 "$feed_path" | /usr/bin/sed -n '3p')"
  final_line="$(/usr/bin/tail -n 4 "$feed_path" | /usr/bin/sed -n '4p')"
  [[ "$first_line" == '<!-- sparkle-signatures:' && "$final_line" == '-->' && \
    "$signature_line" == 'edSignature: '* && "$length_line" == 'length: '* ]] ||
    die "invalid signed feed block" || return 1
  signature="${signature_line#edSignature: }"
  length="${length_line#length: }"
  is_decimal "$length" || die "invalid signed feed block" || return 1
  if decimal_is_greater "$length" "$total_length"; then
    die "invalid signed feed block" || return 1
  fi

  feed_counter=$((feed_counter + 1))
  content_path="$work_dir/feed-content-$feed_counter.xml"
  block_path="$work_dir/feed-block-$feed_counter"
  expected_block="$work_dir/expected-feed-block-$feed_counter"
  /bin/dd if="$feed_path" of="$content_path" bs=1 count="$length" 2>/dev/null ||
    die "invalid signed feed block" || return 1
  printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
    "$signature" "$length" >"$expected_block"
  block_length="$(/usr/bin/stat -f '%z' "$expected_block")"
  [[ "$total_length" == "$((length + block_length))" ]] ||
    die "invalid signed feed block" || return 1
  /bin/dd if="$feed_path" of="$block_path" bs=1 skip="$length" 2>/dev/null ||
    die "invalid signed feed block" || return 1
  /usr/bin/cmp -s "$expected_block" "$block_path" ||
    die "invalid signed feed block" || return 1
  verify_ed25519_signature "$content_path" "$signature" "$description"

  if LC_ALL=C /usr/bin/grep -a -F '<!DOCTYPE' "$content_path" >/dev/null; then
    die "$description must not contain a document type declaration" || return 1
  fi
  /usr/bin/xmllint --nonet --noout "$content_path" >/dev/null 2>&1 ||
    die "$description is not valid XML" || return 1
  VERIFIED_FEED_CONTENT="$content_path"
}

xml_count() {
  /usr/bin/xmllint --nonet --xpath "count($2)" "$1" 2>/dev/null
}

xml_string() {
  /usr/bin/xmllint --nonet --xpath "string($2)" "$1" 2>/dev/null
}

validate_feed_shape() {
  local feed_path="$1" description="$2" content item enclosure sparkle_selector count

  extract_and_verify_signed_feed "$feed_path" "$description"
  content="$VERIFIED_FEED_CONTENT"
  item="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()='']"
  enclosure="$item/*[local-name()='enclosure' and namespace-uri()='']"
  sparkle_selector="namespace-uri()='$SPARKLE_NAMESPACE'"

  [[ "$(xml_count "$content" "/*[local-name()='rss' and namespace-uri()='']")" == 1 ]] ||
    die "$description must contain exactly one RSS root" || return 1
  [[ "$(xml_count "$content" "/*[local-name()='rss' and namespace-uri()='']/@version")" == 1 && \
    "$(xml_string "$content" "/*[local-name()='rss' and namespace-uri()='']/@version")" == 2.0 ]] ||
    die "$description must use RSS version 2.0" || return 1
  [[ "$(xml_count "$content" "/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']")" == 1 ]] ||
    die "$description must contain exactly one RSS channel" || return 1
  [[ "$(xml_count "$content" "$item")" == 1 ]] ||
    die "feed must contain exactly one entry" || return 1
  [[ "$(xml_count "$content" "$enclosure")" == 1 ]] ||
    die "$description must contain exactly one enclosure" || return 1
  [[ "$(xml_count "$content" "$item/*[local-name()='version' and $sparkle_selector]")" == 1 ]] ||
    die "$description must contain exactly one sparkle:version" || return 1
  [[ "$(xml_count "$content" "$item/*[local-name()='shortVersionString' and $sparkle_selector]")" == 1 ]] ||
    die "$description must contain exactly one sparkle:shortVersionString" || return 1
  [[ "$(xml_count "$content" "$item/*[local-name()='minimumSystemVersion' and $sparkle_selector]")" == 1 ]] ||
    die "$description must contain exactly one sparkle:minimumSystemVersion" || return 1
  [[ "$(xml_count "$content" "$enclosure/@url")" == 1 && \
    "$(xml_count "$content" "$enclosure/@length")" == 1 && \
    "$(xml_count "$content" "$enclosure/@type")" == 1 ]] ||
    die "$description enclosure is missing required attributes" || return 1
  [[ "$(xml_count "$content" "$enclosure/@*[local-name()='edSignature' and $sparkle_selector]")" == 1 ]] ||
    die "enclosure is missing an Ed25519 signature" || return 1
  [[ "$(xml_count "$content" "$enclosure/@*")" == 4 ]] ||
    die "$description enclosure contains unexpected attributes" || return 1
  [[ "$(xml_string "$content" "$enclosure/@type")" == application/octet-stream ]] ||
    die "$description enclosure has an unexpected content type" || return 1
  count="$(xml_count "$content" "$item//*[local-name()='deltas' and $sparkle_selector] | $item/*[local-name()='deltas' and $sparkle_selector]")"
  [[ "$count" == 0 ]] || die "feed must not contain deltas" || return 1
  [[ "$(xml_count "$content" "$item/*[local-name()='channel' and $sparkle_selector]")" == 0 ]] ||
    die "feed must not contain a channel" || return 1
  [[ "$(xml_count "$content" "$item/*[local-name()='description' and namespace-uri()=''] | $item/*[(local-name()='releaseNotesLink' or local-name()='fullReleaseNotesLink') and $sparkle_selector]")" == 0 ]] ||
    die "feed must not contain release notes" || return 1

  FEED_BUILD="$(xml_string "$content" "$item/*[local-name()='version' and $sparkle_selector]")"
  FEED_VERSION="$(xml_string "$content" "$item/*[local-name()='shortVersionString' and $sparkle_selector]")"
  FEED_MINIMUM_SYSTEM="$(xml_string "$content" "$item/*[local-name()='minimumSystemVersion' and $sparkle_selector]")"
  FEED_ENCLOSURE_URL="$(xml_string "$content" "$enclosure/@url")"
  FEED_ENCLOSURE_LENGTH="$(xml_string "$content" "$enclosure/@length")"
  FEED_ARCHIVE_SIGNATURE="$(xml_string "$content" "$enclosure/@*[local-name()='edSignature' and $sparkle_selector]")"
  [[ "$FEED_BUILD" =~ ^[1-9][0-9]*$ ]] || die "invalid sparkle:version" || return 1
  [[ "$FEED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "invalid sparkle:shortVersionString" || return 1
  is_decimal "$FEED_ENCLOSURE_LENGTH" || die "invalid enclosure length" || return 1
}

validate_previous_mode() {
  local feed_path="$1" version_config="$2" update_config="$3" sparkle_source="$4"
  local expected_archive expected_url

  assert_real_file "$version_config" "version config"
  assert_real_file "$update_config" "update config"
  load_version_config "$version_config"
  load_update_config "$update_config"
  compile_sparkle_verifier "$sparkle_source"
  validate_feed_shape "$feed_path" "Production Feed"
  decimal_is_greater "$BUILD_NUMBER" "$FEED_BUILD" ||
    die "candidate build must be greater than Production Feed build" || return 1
  [[ "$FEED_MINIMUM_SYSTEM" == "$MIN_SYSTEM_VERSION" ]] ||
    die "minimum system version must match the Production Feed" || return 1
  expected_archive="CodexRadar-v${FEED_VERSION}-macos-universal.zip"
  expected_url="https://github.com/tangwz/codex-radar/releases/download/v${FEED_VERSION}/${expected_archive}"
  [[ "$FEED_ENCLOSURE_URL" == "$expected_url" ]] ||
    die "Production Feed enclosure URL must be version-fixed" || return 1
}

extract_archive_info_plist() {
  local archive_path="$1" output_path="$2"

  /usr/bin/python3 - "$archive_path" "$output_path" <<'PYTHON'
import os
import stat
import sys
import zipfile

archive_path, output_path = sys.argv[1:]
expected_path = "CodexRadar.app/Contents/Info.plist"

try:
    archive = zipfile.ZipFile(archive_path)
except (OSError, zipfile.BadZipFile) as error:
    raise SystemExit("invalid update archive: {}".format(error))

with archive:
    matches = []
    for entry in archive.infolist():
        name = entry.filename
        if not name or "\\" in name or "\x00" in name or name.startswith("/"):
            raise SystemExit("archive contains an unsafe path")
        components = name.rstrip("/").split("/")
        if any(component in ("", ".", "..") for component in components):
            raise SystemExit("archive contains an unsafe path")
        if name == expected_path:
            matches.append(entry)
    if len(matches) != 1:
        raise SystemExit("archive must contain exactly one final Info.plist")
    entry = matches[0]
    file_type = (entry.external_attr >> 16) & stat.S_IFMT(0o177777)
    if file_type not in (0, stat.S_IFREG) or entry.flag_bits & 0x1:
        raise SystemExit("archive final Info.plist must be an unencrypted regular file")
    if entry.file_size <= 0 or entry.file_size > 1024 * 1024:
        raise SystemExit("archive final Info.plist has an invalid size")
    try:
        data = archive.read(entry)
    except (KeyError, OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise SystemExit("unable to read archive final Info.plist: {}".format(error))
    descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
    except Exception:
        os.close(descriptor)
        raise
PYTHON
}

validate_info_plist() {
  local info_plist="$1"

  assert_real_file "$info_plist" "final Info.plist"
  /usr/bin/plutil -lint "$info_plist" >/dev/null
  assert_plist_value "$info_plist" CFBundleIdentifier "$BUNDLE_ID" \
    "final Info.plist bundle identifier does not match"
  assert_plist_value "$info_plist" CFBundleShortVersionString "$MARKETING_VERSION" \
    "final Info.plist version does not match version.env"
  assert_plist_value "$info_plist" CFBundleVersion "$BUILD_NUMBER" \
    "final Info.plist build does not match version.env"
  assert_plist_value "$info_plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION" \
    "final Info.plist minimum system version does not match release policy"
  assert_plist_value "$info_plist" SUFeedURL "$PRODUCTION_FEED_URL" \
    "final Info.plist feed URL does not match update config"
  assert_plist_value "$info_plist" SUPublicEDKey "$SPARKLE_PUBLIC_ED_KEY" \
    "final Info.plist public key does not match update config"
  for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction \
    SURequireSignedFeed CodexRadarUpdatesEnabled; do
    assert_plist_value "$info_plist" "$key" true "$key must equal true in final Info.plist"
  done
}

assert_input_directory_layout() {
  local directory="$1" archive_name="$2" entry_path entry_name count=0

  assert_real_directory "$directory" "appcast input directory"
  while IFS= read -r -d '' entry_path; do
    entry_name="$(/usr/bin/basename "$entry_path")"
    case "$entry_name" in
      "$archive_name"|appcast.xml) ;;
      *) die "appcast input directory contains an unexpected entry: $entry_name" || return 1 ;;
    esac
    count=$((count + 1))
  done < <(/usr/bin/find -s "$directory" -mindepth 1 -maxdepth 1 -print0)
  [[ "$count" -eq 2 ]] || die "appcast input directory must contain exactly two files" || return 1
  assert_real_file "$directory/$archive_name" "prepared archive"
  assert_real_file "$directory/appcast.xml" "signed appcast"
}

validate_artifacts_mode() {
  local inputs_path="$1" archive_path="$2" manifest_path="$3" info_plist="$4"
  local version_config="$5" update_config="$6" sparkle_source="$7"
  local archive_name archive_length archive_sha extracted_plist
  local production_signature qualification_signature expected_production_url

  assert_real_directory "$inputs_path" "appcast inputs"
  assert_real_file "$archive_path" "release archive"
  assert_real_file "$manifest_path" "release manifest"
  assert_real_file "$version_config" "version config"
  assert_real_file "$update_config" "update config"
  load_version_config "$version_config"
  load_update_config "$update_config"
  assert_real_file "$inputs_path/manifest" "prepared manifest"
  assert_real_file "$inputs_path/Info.plist" "prepared Info.plist"
  /usr/bin/cmp -s "$manifest_path" "$inputs_path/manifest" ||
    die "manifest bytes differ from prepared inputs" || return 1
  /usr/bin/cmp -s "$info_plist" "$inputs_path/Info.plist" ||
    die "Info.plist bytes differ from prepared inputs" || return 1
  load_manifest "$manifest_path"
  validate_info_plist "$info_plist"
  compile_sparkle_verifier "$sparkle_source"

  archive_name="$(/usr/bin/basename "$archive_path")"
  [[ "$archive_name" == "$MANIFEST_ARCHIVE_NAME" && \
    "$archive_name" == "$(release_asset_basename).zip" ]] ||
    die "archive name does not match manifest and version.env" || return 1
  [[ "$MANIFEST_VERSION" == "$MARKETING_VERSION" ]] ||
    die "manifest version does not match version.env" || return 1
  [[ "$MANIFEST_BUILD" == "$BUILD_NUMBER" ]] ||
    die "manifest build does not match version.env" || return 1
  archive_length="$(/usr/bin/stat -f '%z' "$archive_path")"
  archive_sha="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
  [[ "$archive_length" == "$MANIFEST_BYTE_LENGTH" ]] ||
    die "manifest byte_length does not match archive" || return 1
  [[ "$archive_sha" == "$MANIFEST_SHA256" ]] ||
    die "manifest sha256 does not match archive" || return 1

  assert_input_directory_layout "$inputs_path/production" "$archive_name"
  assert_input_directory_layout "$inputs_path/qualification" "$archive_name"
  /usr/bin/cmp -s "$archive_path" "$inputs_path/production/$archive_name" ||
    die "production archive bytes differ from release archive" || return 1
  /usr/bin/cmp -s "$archive_path" "$inputs_path/qualification/$archive_name" ||
    die "qualification archive bytes differ from release archive" || return 1

  extracted_plist="$work_dir/archive-Info.plist"
  extract_archive_info_plist "$archive_path" "$extracted_plist"
  /usr/bin/cmp -s "$info_plist" "$extracted_plist" ||
    die "archive Info.plist bytes differ from final Info.plist" || return 1
  validate_info_plist "$extracted_plist"

  validate_feed_shape "$inputs_path/production/appcast.xml" "production signed feed"
  [[ "$FEED_BUILD" == "$BUILD_NUMBER" ]] ||
    die "sparkle:version does not match version.env" || return 1
  [[ "$FEED_VERSION" == "$MARKETING_VERSION" ]] ||
    die "sparkle:shortVersionString does not match version.env" || return 1
  [[ "$FEED_MINIMUM_SYSTEM" == "$MIN_SYSTEM_VERSION" ]] ||
    die "minimum system version does not match final Info.plist" || return 1
  [[ "$FEED_ENCLOSURE_LENGTH" == "$archive_length" ]] ||
    die "enclosure length does not match archive" || return 1
  expected_production_url="https://github.com/tangwz/codex-radar/releases/download/v${MARKETING_VERSION}/${archive_name}"
  [[ "$FEED_ENCLOSURE_URL" == "$expected_production_url" ]] ||
    die "production enclosure URL must be version-fixed" || return 1
  production_signature="$FEED_ARCHIVE_SIGNATURE"
  verify_ed25519_signature "$archive_path" "$production_signature" "production archive"

  validate_feed_shape "$inputs_path/qualification/appcast.xml" "qualification signed feed"
  [[ "$FEED_BUILD" == "$BUILD_NUMBER" ]] ||
    die "sparkle:version does not match version.env" || return 1
  [[ "$FEED_VERSION" == "$MARKETING_VERSION" ]] ||
    die "sparkle:shortVersionString does not match version.env" || return 1
  [[ "$FEED_MINIMUM_SYSTEM" == "$MIN_SYSTEM_VERSION" ]] ||
    die "minimum system version does not match final Info.plist" || return 1
  [[ "$FEED_ENCLOSURE_LENGTH" == "$archive_length" ]] ||
    die "enclosure length does not match archive" || return 1
  [[ "$FEED_ENCLOSURE_URL" == "$archive_name" ]] ||
    die "qualification enclosure URL must be relative" || return 1
  qualification_signature="$FEED_ARCHIVE_SIGNATURE"
  [[ "$qualification_signature" == "$production_signature" ]] ||
    die "production and qualification archive signatures differ" || return 1
  verify_ed25519_signature "$archive_path" "$qualification_signature" "qualification archive"
}

validate_cas_mode() {
  local current_feed="$1" current_absent="$2" expected_feed="$3"
  local expected_absent="$4" candidate_feed="$5"

  assert_real_file "$candidate_feed" "candidate feed"
  if [[ "$current_absent" == false ]]; then
    assert_real_file "$current_feed" "current feed"
    if /usr/bin/cmp -s "$current_feed" "$candidate_feed"; then
      printf 'cas_state=already-active\n'
      return 0
    fi
  fi
  if [[ "$expected_absent" == true ]]; then
    [[ "$current_absent" == true ]] ||
      die "CAS conflict: expected an absent current feed" || return 1
    printf 'cas_state=ready-bootstrap\n'
    return 0
  fi
  assert_real_file "$expected_feed" "expected previous feed"
  [[ "$current_absent" == false ]] || die "CAS conflict: current feed is absent" || return 1
  /usr/bin/cmp -s "$current_feed" "$expected_feed" ||
    die "CAS conflict: current feed is neither expected nor candidate" || return 1
  printf 'cas_state=ready\n'
}

mode=""
feed_path=""
inputs_path=""
archive_path=""
manifest_path=""
info_plist=""
version_config=""
update_config=""
sparkle_source=""
current_feed=""
current_absent=false
expected_feed=""
expected_absent=false
candidate_feed=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ -z "$mode" && "$#" -ge 2 ]] || usage
      mode="$2"
      shift 2
      ;;
    --feed)
      [[ -z "$feed_path" && "$#" -ge 2 ]] || usage
      feed_path="$2"
      shift 2
      ;;
    --inputs)
      [[ -z "$inputs_path" && "$#" -ge 2 ]] || usage
      inputs_path="$2"
      shift 2
      ;;
    --archive)
      [[ -z "$archive_path" && "$#" -ge 2 ]] || usage
      archive_path="$2"
      shift 2
      ;;
    --manifest)
      [[ -z "$manifest_path" && "$#" -ge 2 ]] || usage
      manifest_path="$2"
      shift 2
      ;;
    --final-info-plist)
      [[ -z "$info_plist" && "$#" -ge 2 ]] || usage
      info_plist="$2"
      shift 2
      ;;
    --version-config)
      [[ -z "$version_config" && "$#" -ge 2 ]] || usage
      version_config="$2"
      shift 2
      ;;
    --update-config)
      [[ -z "$update_config" && "$#" -ge 2 ]] || usage
      update_config="$2"
      shift 2
      ;;
    --sparkle-source)
      [[ -z "$sparkle_source" && "$#" -ge 2 ]] || usage
      sparkle_source="$2"
      shift 2
      ;;
    --current-feed)
      [[ -z "$current_feed" && "$current_absent" == false && "$#" -ge 2 ]] || usage
      current_feed="$2"
      shift 2
      ;;
    --current-absent)
      [[ -z "$current_feed" && "$current_absent" == false ]] || usage
      current_absent=true
      shift
      ;;
    --expected-previous-feed)
      [[ -z "$expected_feed" && "$expected_absent" == false && "$#" -ge 2 ]] || usage
      expected_feed="$2"
      shift 2
      ;;
    --expected-previous-absent)
      [[ -z "$expected_feed" && "$expected_absent" == false ]] || usage
      expected_absent=true
      shift
      ;;
    --candidate-feed)
      [[ -z "$candidate_feed" && "$#" -ge 2 ]] || usage
      candidate_feed="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$mode" in
  previous)
    [[ -n "$feed_path" && -n "$version_config" && -n "$update_config" && \
      -n "$sparkle_source" ]] || usage
    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-update-verify.XXXXXX")"
    validate_previous_mode "$feed_path" "$version_config" "$update_config" "$sparkle_source"
    ;;
  artifacts)
    [[ -n "$inputs_path" && -n "$archive_path" && -n "$manifest_path" && \
      -n "$info_plist" && -n "$version_config" && -n "$update_config" && \
      -n "$sparkle_source" ]] || usage
    work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-update-verify.XXXXXX")"
    validate_artifacts_mode "$inputs_path" "$archive_path" "$manifest_path" \
      "$info_plist" "$version_config" "$update_config" "$sparkle_source"
    ;;
  cas)
    [[ -n "$candidate_feed" && ( -n "$current_feed" || "$current_absent" == true ) && \
      ( -n "$expected_feed" || "$expected_absent" == true ) ]] || usage
    validate_cas_mode "$current_feed" "$current_absent" "$expected_feed" \
      "$expected_absent" "$candidate_feed"
    ;;
  *) usage ;;
esac
