#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"

usage() {
  cat >&2 <<EOF
usage: $0 --output PATH --archive PATH --manifest PATH --final-info-plist PATH --version-config PATH --update-config PATH --sparkle-source PATH (--production-feed PATH | --bootstrap --release-history PATH)
EOF
  return 2
}

assert_real_file() {
  local path="$1" description="$2"

  [[ -f "$path" && ! -L "$path" ]] || die "$description must be a real file" || return 1
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

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

assert_plist_value() {
  local plist_path="$1" key="$2" expected="$3" message="$4" actual

  actual="$(plist_value "$plist_path" "$key" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || die "$message" || return 1
}

validate_info_plist() {
  local info_plist="$1" key

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
        [[ "$value" == adhoc || "$value" == developer-id ]] ||
          die "invalid manifest signing_mode" || return 1
        ;;
      distribution_trust)
        [[ "$seen_trust" == false ]] || die "duplicate distribution_trust" || return 1
        seen_trust=true
        MANIFEST_DISTRIBUTION_TRUST="$value"
        case "$MANIFEST_DISTRIBUTION_TRUST" in
          locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted | \
            developer-id-notarized) ;;
          *) die "invalid manifest distribution_trust" || return 1 ;;
        esac
        ;;
      *) die "unknown manifest key: $key" || return 1 ;;
    esac
  done <"$manifest_path"

  [[ "$seen_archive" == true && "$seen_version" == true && "$seen_build" == true && \
    "$seen_length" == true && "$seen_sha" == true && "$seen_mode" == true && \
    "$seen_trust" == true ]] || die "manifest is missing required keys" || return 1
  [[ "$MANIFEST_ARCHIVE_NAME" == "$(release_asset_basename).zip" ]] ||
    die "manifest archive_name does not match version.env" || return 1
  [[ "$MANIFEST_VERSION" == "$MARKETING_VERSION" ]] ||
    die "manifest version does not match version.env" || return 1
  [[ "$MANIFEST_BUILD" == "$BUILD_NUMBER" ]] ||
    die "manifest build does not match version.env" || return 1
  [[ "$MANIFEST_BYTE_LENGTH" =~ ^(0|[1-9][0-9]*)$ ]] ||
    die "invalid manifest byte_length" || return 1
  [[ "$MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid manifest sha256" || return 1
  case "$MANIFEST_SIGNING_MODE:$MANIFEST_DISTRIBUTION_TRUST" in
    adhoc:locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted | \
      developer-id:developer-id-notarized) ;;
    *) die "invalid manifest signing trust" || return 1 ;;
  esac
}

validate_release_history_empty() {
  local history_path="$1" history_xml="$2" count

  assert_real_file "$history_path" "GitHub Release history"
  /usr/bin/plutil -convert xml1 -o "$history_xml" "$history_path" >/dev/null 2>&1 ||
    die "GitHub Release history must be a JSON array" || return 1
  count="$(/usr/bin/xmllint --nonet --xpath 'count(/plist/array/*)' "$history_xml" 2>/dev/null)" ||
    die "GitHub Release history must be a JSON array" || return 1
  [[ "$(/usr/bin/xmllint --nonet --xpath 'count(/plist/array)' "$history_xml" 2>/dev/null)" == 1 ]] ||
    die "GitHub Release history must be a JSON array" || return 1
  [[ "$count" == 0 ]] || die "bootstrap requires empty GitHub Release history" || return 1
}

output_argument=""
archive_path=""
manifest_path=""
info_plist=""
version_config=""
update_config=""
sparkle_source=""
production_feed=""
production_feed_supplied=false
bootstrap=false
release_history=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      [[ -z "$output_argument" && "$#" -ge 2 ]] || usage
      output_argument="$2"
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
    --production-feed)
      [[ "$production_feed_supplied" == false && "$#" -ge 2 ]] || usage
      production_feed_supplied=true
      production_feed="$2"
      shift 2
      ;;
    --bootstrap)
      [[ "$bootstrap" == false ]] || usage
      bootstrap=true
      shift
      ;;
    --release-history)
      [[ -z "$release_history" && "$#" -ge 2 ]] || usage
      release_history="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$output_argument" && -n "$archive_path" && -n "$manifest_path" && \
  -n "$info_plist" && -n "$version_config" && -n "$update_config" && \
  -n "$sparkle_source" ]] || usage
assert_real_file "$archive_path" "release archive"
assert_real_file "$manifest_path" "release manifest"
assert_real_file "$version_config" "version config"
assert_real_file "$update_config" "update config"
load_version_config "$version_config"
load_update_config "$update_config"
validate_info_plist "$info_plist"
load_manifest "$manifest_path"

archive_name="$(/usr/bin/basename "$archive_path")"
[[ "$archive_name" == "$MANIFEST_ARCHIVE_NAME" ]] ||
  die "archive name does not match manifest"
archive_length="$(/usr/bin/stat -f '%z' "$archive_path")"
archive_sha="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
[[ "$archive_length" == "$MANIFEST_BYTE_LENGTH" ]] ||
  die "manifest byte_length does not match archive"
[[ "$archive_sha" == "$MANIFEST_SHA256" ]] || die "manifest sha256 does not match archive"

output_parent="$(/usr/bin/dirname "$output_argument")"
output_name="$(/usr/bin/basename "$output_argument")"
[[ -n "$output_name" && "$output_name" != . && "$output_name" != .. ]] ||
  die "invalid appcast output directory name"
[[ -d "$output_parent" && ! -L "$output_parent" ]] ||
  die "appcast output parent must be a real directory"
output_parent="$(/bin/realpath "$output_parent")"
output_path="$output_parent/$output_name"
[[ ! -e "$output_path" && ! -L "$output_path" ]] ||
  die "appcast output path already exists"

stage="$(/usr/bin/mktemp -d "$output_parent/.appcast-inputs.XXXXXX")"
/bin/chmod 700 "$stage"
committed=false
cleanup() {
  if [[ "$committed" == false && -n "${stage:-}" && -d "$stage" && ! -L "$stage" ]]; then
    /bin/rm -rf "$stage"
  fi
}
handle_signal() {
  exit 130
}
trap cleanup EXIT
trap handle_signal HUP INT TERM

if [[ "$bootstrap" == true ]]; then
  [[ "$MARKETING_VERSION" == 0.1.0 && "$BUILD_NUMBER" == 1 ]] ||
    die "bootstrap requires App Version 0.1.0 and build 1"
  [[ "$production_feed_supplied" == false ]] ||
    die "bootstrap requires an absent Production Feed"
  [[ -n "$release_history" ]] || die "bootstrap requires GitHub Release history"
  validate_release_history_empty "$release_history" "$stage/release-history.plist"
  /bin/rm -f "$stage/release-history.plist"
  : >"$stage/bootstrap"
else
  [[ "$production_feed_supplied" == true ]] || die "existing Production Feed is required"
  assert_real_file "$production_feed" "Production Feed"
  [[ -z "$release_history" ]] || die "release history is only valid with --bootstrap"
  "$ROOT_DIR/script/verify_update_artifacts.sh" --mode previous \
    --feed "$production_feed" \
    --version-config "$version_config" \
    --update-config "$update_config" \
    --sparkle-source "$sparkle_source"
fi

/bin/mkdir -m 700 "$stage/production" "$stage/qualification"
/bin/cp "$archive_path" "$stage/production/$archive_name"
/bin/cp "$archive_path" "$stage/qualification/$archive_name"
/bin/cp "$manifest_path" "$stage/manifest"
/bin/cp "$info_plist" "$stage/Info.plist"
if [[ "$bootstrap" == false ]]; then
  /bin/cp "$production_feed" "$stage/production/appcast.xml"
  /bin/cp "$production_feed" "$stage/qualification/appcast.xml"
  /bin/cp "$production_feed" "$stage/previous-appcast.xml"
fi
printf 'https://github.com/tangwz/codex-radar/releases/download/v%s/\n' \
  "$MARKETING_VERSION" >"$stage/production-download-url-prefix"
printf './\n' >"$stage/qualification-download-url-prefix"

/usr/bin/cmp -s "$archive_path" "$stage/production/$archive_name" ||
  die "production archive copy differs from source"
/usr/bin/cmp -s "$archive_path" "$stage/qualification/$archive_name" ||
  die "qualification archive copy differs from source"
/usr/bin/cmp -s "$stage/production/$archive_name" "$stage/qualification/$archive_name" ||
  die "production and qualification archive inputs differ"
/usr/bin/cmp -s "$manifest_path" "$stage/manifest" || die "manifest copy differs from source"
/usr/bin/cmp -s "$info_plist" "$stage/Info.plist" || die "Info.plist copy differs from source"
if [[ "$bootstrap" == false ]]; then
  /usr/bin/cmp -s "$production_feed" "$stage/production/appcast.xml" ||
    die "production feed copy differs from source"
  /usr/bin/cmp -s "$production_feed" "$stage/qualification/appcast.xml" ||
    die "qualification feed copy differs from source"
  /usr/bin/cmp -s "$production_feed" "$stage/previous-appcast.xml" ||
    die "previous feed snapshot differs from source"
fi

[[ ! -e "$output_path" && ! -L "$output_path" ]] ||
  die "appcast output path appeared during preparation"
/bin/mv "$stage" "$output_path"
committed=true
trap - EXIT HUP INT TERM
printf 'Prepared %s\n' "$output_path"
