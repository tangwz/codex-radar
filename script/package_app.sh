#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

EXPECTED_SPARKLE_VERSION="2.9.4"
EXPECTED_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"
COPYRIGHT="© 2026 Terence Tang. All rights reserved."

usage() {
  echo "usage: $0 --output PATH --configuration debug|release --architectures ARCH_LIST --updates-enabled true|false" >&2
  return 2
}

load_update_config() {
  local config_path="$1" line key value
  local seen_sparkle_version=false
  local seen_public_key=false
  local seen_feed_url=false

  SPARKLE_VERSION=""
  SPARKLE_PUBLIC_ED_KEY=""
  PRODUCTION_FEED_URL=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || die "invalid update config line" || return 1
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      SPARKLE_VERSION)
        [[ "$seen_sparkle_version" == false ]] || die "duplicate SPARKLE_VERSION" || return 1
        seen_sparkle_version=true
        SPARKLE_VERSION="$value"
        ;;
      SPARKLE_PUBLIC_ED_KEY)
        [[ "$seen_public_key" == false ]] || die "duplicate SPARKLE_PUBLIC_ED_KEY" || return 1
        seen_public_key=true
        SPARKLE_PUBLIC_ED_KEY="$value"
        ;;
      PRODUCTION_FEED_URL)
        [[ "$seen_feed_url" == false ]] || die "duplicate PRODUCTION_FEED_URL" || return 1
        seen_feed_url=true
        PRODUCTION_FEED_URL="$value"
        ;;
      *) die "unknown update key: $key" || return 1 ;;
    esac
  done <"$config_path"

  [[ "$SPARKLE_VERSION" == "$EXPECTED_SPARKLE_VERSION" ]] ||
    die "SPARKLE_VERSION must equal $EXPECTED_SPARKLE_VERSION" || return 1
  [[ "$PRODUCTION_FEED_URL" == "$EXPECTED_FEED_URL" ]] ||
    die "PRODUCTION_FEED_URL must equal $EXPECTED_FEED_URL" || return 1
}

validate_resolved_sparkle_version() {
  local resolved_path="$1" resolved_version

  resolved_version="$(/usr/bin/awk '
    /"identity"[[:space:]]*:[[:space:]]*"sparkle"/ { in_sparkle = 1 }
    in_sparkle && /"version"[[:space:]]*:/ {
      value = $0
      sub(/^.*"version"[[:space:]]*:[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
      exit
    }
  ' "$resolved_path")"
  [[ "$resolved_version" == "$EXPECTED_SPARKLE_VERSION" ]] ||
    die "Package.resolved must lock Sparkle $EXPECTED_SPARKLE_VERSION" || return 1
}

validate_public_key() {
  local decoded_path="$1" decoded_size

  [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  if ! printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D >"$decoded_path" 2>/dev/null; then
    die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
  fi
  decoded_size="$(/usr/bin/wc -c <"$decoded_path" | /usr/bin/tr -d ' ')"
  [[ "$decoded_size" == "32" ]] || die "invalid SPARKLE_PUBLIC_ED_KEY" || return 1
}

normalize_resources() {
  local resource_root="$1" output_path="$2" relative_path digest target

  : >"$output_path"
  while IFS= read -r relative_path; do
    if [[ -L "$resource_root/$relative_path" ]]; then
      target="$(/usr/bin/readlink "$resource_root/$relative_path")"
      printf 'link\t%s\t%s\n' "$relative_path" "$target" >>"$output_path"
    elif [[ -d "$resource_root/$relative_path" ]]; then
      printf 'directory\t%s\n' "$relative_path" >>"$output_path"
    elif [[ -f "$resource_root/$relative_path" ]]; then
      digest="$(/usr/bin/shasum -a 256 "$resource_root/$relative_path" | /usr/bin/awk '{print $1}')"
      printf 'file\t%s\t%s\n' "$relative_path" "$digest" >>"$output_path"
    else
      die "unsupported resource entry: $relative_path" || return 1
    fi
  done < <(
    cd "$resource_root"
    /usr/bin/find . -mindepth 1 -print | LC_ALL=C /usr/bin/sort
  )
}

validate_framework_tree() {
  local framework_path="$1" framework_real current_path link_path target_real

  [[ -d "$framework_path" && ! -L "$framework_path" ]] ||
    die "Sparkle.framework must be a real directory" || return 1
  framework_real="$(/bin/realpath "$framework_path")"
  current_path="$framework_path/Versions/Current"
  [[ -L "$current_path" ]] || die "Sparkle.framework Versions/Current must be a symlink" || return 1

  while IFS= read -r link_path; do
    target_real="$(/bin/realpath "$link_path" 2>/dev/null)" ||
      die "unresolved Sparkle.framework symlink: $link_path" || return 1
    case "$target_real" in
      "$framework_real"|"$framework_real"/*) ;;
      *) die "escaped Sparkle.framework symlink: $link_path" || return 1 ;;
    esac
  done < <(/usr/bin/find "$framework_path" -type l -print | LC_ALL=C /usr/bin/sort)
}

assert_framework_version() {
  local framework_path="$1" framework_version

  framework_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
    "$framework_path/Versions/Current/Resources/Info.plist")"
  [[ "$framework_version" == "$EXPECTED_SPARKLE_VERSION" ]] ||
    die "embedded Sparkle.framework must equal $EXPECTED_SPARKLE_VERSION" || return 1
}

assert_framework_rpath() {
  local executable_path="$1"

  /usr/bin/otool -l "$executable_path" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
      if ($2 == "@executable_path/../Frameworks") found = 1
      in_rpath = 0
    }
    END { exit(found ? 0 : 1) }
  ' || die "missing LC_RPATH @executable_path/../Frameworks" || return 1
}

write_info_plist() {
  local plist_path="$1" updates_enabled="$2"

  /usr/bin/plutil -create xml1 "$plist_path"
  /usr/bin/plutil -insert CFBundleExecutable -string "$APP_NAME" "$plist_path"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$plist_path"
  /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$plist_path"
  /usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$plist_path"
  /usr/bin/plutil -insert CFBundleLocalizations -json '["en","zh-Hans"]' "$plist_path"
  /usr/bin/plutil -insert CFBundleName -string "Codex Radar" "$plist_path"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$plist_path"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$plist_path"
  /usr/bin/plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$plist_path"
  /usr/bin/plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$plist_path"
  /usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.developer-tools "$plist_path"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$plist_path"
  /usr/bin/plutil -insert LSUIElement -bool true "$plist_path"
  /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$plist_path"

  if [[ "$updates_enabled" == true ]]; then
    /usr/bin/plutil -insert SUFeedURL -string "$PRODUCTION_FEED_URL" "$plist_path"
    /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$plist_path"
    /usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "$plist_path"
    /usr/bin/plutil -insert SUAutomaticallyUpdate -bool true "$plist_path"
    /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$plist_path"
    /usr/bin/plutil -insert SURequireSignedFeed -bool true "$plist_path"
    /usr/bin/plutil -insert CodexRadarUpdatesEnabled -bool true "$plist_path"
  else
    /usr/bin/plutil -insert CodexRadarUpdatesEnabled -bool false "$plist_path"
  fi

  /usr/bin/plutil -lint "$plist_path" >/dev/null
}

output_path=""
configuration=""
architecture_list=""
updates_enabled=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      [[ -z "$output_path" && "$#" -ge 2 ]] || usage
      output_path="$2"
      shift 2
      ;;
    --configuration)
      [[ -z "$configuration" && "$#" -ge 2 ]] || usage
      configuration="$2"
      shift 2
      ;;
    --architectures)
      [[ -z "$architecture_list" && "$#" -ge 2 ]] || usage
      architecture_list="$2"
      shift 2
      ;;
    --updates-enabled)
      [[ -z "$updates_enabled" && "$#" -ge 2 ]] || usage
      updates_enabled="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$output_path" && -n "$configuration" && -n "$architecture_list" && -n "$updates_enabled" ]] || usage
case "$configuration" in
  debug|release) ;;
  *) die "configuration must be debug or release" ;;
esac
case "$updates_enabled" in
  true|false) ;;
  *) die "updates-enabled must be true or false" ;;
esac
if [[ "$updates_enabled" == true && "$configuration" != release ]]; then
  die "updates may only be enabled for release configuration"
fi

[[ "$architecture_list" != *$'\n'* && "$architecture_list" != *$'\r'* ]] ||
  die "architectures must be a single whitespace-separated line"
requested_architectures=()
IFS=$' \t' read -r -a requested_architectures <<<"$architecture_list"
architectures=()
for architecture in "${requested_architectures[@]}"; do
  case "$architecture" in
    arm64|x86_64) ;;
    *) die "unknown architecture: $architecture" ;;
  esac
  for existing_architecture in "${architectures[@]:-}"; do
    [[ "$existing_architecture" != "$architecture" ]] || die "duplicate architecture: $architecture"
  done
  architectures+=("$architecture")
done
[[ "${#architectures[@]}" -gt 0 ]] || die "architectures must not be empty"

load_version_config "$ROOT_DIR/version.env"
load_update_config "$ROOT_DIR/config/update.env"
validate_resolved_sparkle_version "$ROOT_DIR/Package.resolved"

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-package.XXXXXX")"
delivery_path=""
destination_path=""
backup_path=""
cleanup() {
  if [[ -n "$backup_path" && (-e "$backup_path" || -L "$backup_path") && \
    -n "$destination_path" && ! -e "$destination_path" && ! -L "$destination_path" ]]; then
    /bin/mv "$backup_path" "$destination_path"
  fi
  [[ -z "$delivery_path" || (! -e "$delivery_path" && ! -L "$delivery_path") ]] || /bin/rm -rf "$delivery_path"
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ "$updates_enabled" == true ]]; then
  validate_public_key "$work_dir/public-key.bin"
fi

swift_executable="$(command -v swift 2>/dev/null || true)"
[[ -n "$swift_executable" ]] || die "swift is required"

binaries=()
resource_bundles=()
bin_paths=()
resource_manifests=()
for architecture in "${architectures[@]}"; do
  scratch_path="$work_dir/scratch-$architecture"
  target_triple="$architecture-apple-macosx$MIN_SYSTEM_VERSION"
  "$swift_executable" build \
    --package-path "$ROOT_DIR" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --scratch-path "$scratch_path" \
    -Xlinker -rpath \
    -Xlinker '@executable_path/../Frameworks'
  bin_path="$("$swift_executable" build \
    --package-path "$ROOT_DIR" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --scratch-path "$scratch_path" \
    --show-bin-path)"
  binary_path="$bin_path/$APP_NAME"
  resource_bundle="$bin_path/$RESOURCE_BUNDLE_NAME"
  [[ -f "$binary_path" && -x "$binary_path" ]] || die "missing executable for $architecture"
  [[ -d "$resource_bundle" ]] || die "missing resource bundle for $architecture"

  resource_manifest="$work_dir/resources-$architecture.txt"
  normalize_resources "$resource_bundle" "$resource_manifest"
  binaries+=("$binary_path")
  resource_bundles+=("$resource_bundle")
  bin_paths+=("$bin_path")
  resource_manifests+=("$resource_manifest")
done

reference_manifest="${resource_manifests[0]}"
for resource_manifest in "${resource_manifests[@]:1}"; do
  /usr/bin/cmp -s "$reference_manifest" "$resource_manifest" ||
    die "resource sets differ between architectures"
done

staged_app="$work_dir/$APP_NAME.app"
contents_path="$staged_app/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
frameworks_path="$contents_path/Frameworks"
executable_path="$macos_path/$APP_NAME"
/bin/mkdir -p "$macos_path" "$resources_path" "$frameworks_path"

/usr/bin/lipo -create "${binaries[@]}" -output "$executable_path"
/bin/chmod +x "$executable_path"
/usr/bin/ditto "${resource_bundles[0]}" "$resources_path"

sparkle_frameworks=()
for bin_path in "${bin_paths[@]}"; do
  framework_matches=()
  while IFS= read -r framework_path; do
    framework_matches+=("$framework_path")
  done < <(/usr/bin/find "$bin_path" -type d -name Sparkle.framework -prune -print | LC_ALL=C /usr/bin/sort)
  [[ "${#framework_matches[@]}" -eq 1 ]] ||
    die "expected exactly one SwiftPM Sparkle.framework, found ${#framework_matches[@]} in $bin_path"

  sparkle_framework="${framework_matches[0]}"
  bin_path_real="$(/bin/realpath "$bin_path")"
  sparkle_framework_real="$(/bin/realpath "$sparkle_framework")"
  case "$sparkle_framework_real" in
    "$bin_path_real"/*) ;;
    *) die "Sparkle.framework escaped the SwiftPM product directory" ;;
  esac
  validate_framework_tree "$sparkle_framework"
  assert_framework_version "$sparkle_framework"
  sparkle_frameworks+=("$sparkle_framework")
done

/usr/bin/ditto "${sparkle_frameworks[0]}" "$frameworks_path/Sparkle.framework"
validate_framework_tree "$frameworks_path/Sparkle.framework"
assert_framework_version "$frameworks_path/Sparkle.framework"

assert_framework_rpath "$executable_path"
write_info_plist "$contents_path/Info.plist" "$updates_enabled"

/bin/mkdir -p "$output_path"
destination_path="$output_path/$APP_NAME.app"
delivery_path="$output_path/.$APP_NAME.app.package.$$"
backup_path="$output_path/.$APP_NAME.app.previous.$$"
[[ ! -e "$delivery_path" && ! -L "$delivery_path" ]] || die "temporary delivery path already exists"
[[ ! -e "$backup_path" && ! -L "$backup_path" ]] || die "temporary backup path already exists"
/usr/bin/ditto "$staged_app" "$delivery_path"

if [[ -e "$destination_path" || -L "$destination_path" ]]; then
  /bin/mv "$destination_path" "$backup_path"
fi
if ! /bin/mv "$delivery_path" "$destination_path"; then
  if [[ -e "$backup_path" || -L "$backup_path" ]]; then
    /bin/mv "$backup_path" "$destination_path"
  fi
  die "failed to install packaged application"
fi
delivery_path=""
if [[ -e "$backup_path" || -L "$backup_path" ]]; then
  /bin/rm -rf "$backup_path"
fi
backup_path=""

echo "Packaged $destination_path"
