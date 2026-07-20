#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

usage() {
  echo "usage: $0 --output PATH --signing-mode adhoc|developer-id" >&2
  return 2
}

validate_developer_id_inputs() {
  [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] ||
    die "developer-id release requires DEVELOPER_ID_APPLICATION" || return 1
  [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]] ||
    die "developer-id release requires APP_STORE_CONNECT_API_KEY_PATH" || return 1
  [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" && ! -L "$APP_STORE_CONNECT_API_KEY_PATH" ]] ||
    die "developer-id release requires a real App Store Connect API key file" || return 1
  [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] ||
    die "developer-id release requires APP_STORE_CONNECT_KEY_ID" || return 1
  [[ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] ||
    die "developer-id release requires APP_STORE_CONNECT_ISSUER_ID" || return 1
}

preflight_archive() {
  local archive_path="$1"

  "$PYTHON_EXECUTABLE" - "$archive_path" <<'PYTHON'
import posixpath
import stat
import sys
import zipfile


def reject(message):
    raise SystemExit(message)


def normalize_path(path, failure_message="archive contains an unsafe path"):
    normalized = []
    for component in path.split("/"):
        if component in ("", "."):
            continue
        if component == "..":
            if not normalized:
                reject(failure_message)
            normalized.pop()
        else:
            normalized.append(component)
    return "/".join(normalized)


def resolve_symlinks(path, symlinks, seen=None):
    seen = set() if seen is None else seen
    components = normalize_path(path, "archive symlink escapes application").split("/")
    for index in range(1, len(components) + 1):
        prefix = "/".join(components[:index])
        if prefix not in symlinks:
            continue
        if prefix in seen:
            reject("archive contains an unsafe symlink cycle")
        target = symlinks[prefix]
        if target.startswith("/"):
            reject("archive symlink escapes application")
        replacement = posixpath.join(posixpath.dirname(prefix), target)
        remainder = "/".join(components[index:])
        resolved = normalize_path(
            posixpath.join(replacement, remainder),
            "archive symlink escapes application",
        )
        if resolved != "CodexRadar.app" and not resolved.startswith("CodexRadar.app/"):
            reject("archive symlink escapes application")
        return resolve_symlinks(resolved, symlinks, seen | {prefix})
    return "/".join(components)


archive_path = sys.argv[1]
try:
    archive = zipfile.ZipFile(archive_path)
except (OSError, zipfile.BadZipFile) as error:
    reject("invalid release archive: {}".format(error))

with archive:
    entries = archive.infolist()
    if not entries:
        reject("release archive is empty")

    names = set()
    symlinks = {}
    for entry in entries:
        name = entry.filename
        if not name or "\\" in name or "\x00" in name or name.startswith("/"):
            reject("archive contains an unsafe path")
        components = name.rstrip("/").split("/")
        if any(component in ("", ".", "..") for component in components):
            reject("archive contains an unsafe path")
        if any(component == "__MACOSX" or component.startswith("._") for component in components):
            reject("archive contains AppleDouble metadata")
        if components[0] != "CodexRadar.app":
            reject("archive contains an unexpected top-level entry")
        normalized_name = "/".join(components)
        if normalized_name in names:
            reject("archive contains duplicate entries")
        names.add(normalized_name)
        if entry.flag_bits & 0x1:
            reject("archive contains an encrypted entry")

        file_type = (entry.external_attr >> 16) & stat.S_IFMT(0o177777)
        if file_type == stat.S_IFLNK:
            try:
                target_bytes = archive.read(entry)
                target = target_bytes.decode("utf-8")
            except (KeyError, OSError, RuntimeError, UnicodeDecodeError, zipfile.BadZipFile):
                reject("archive contains an invalid symlink")
            if not target or "\x00" in target or "\\" in target:
                reject("archive contains an invalid symlink")
            symlinks[normalized_name] = target
        elif file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
            reject("archive contains an unsupported entry type")

    if "CodexRadar.app" not in names:
        reject("archive does not contain the application root")
    for link_name, link_target in symlinks.items():
        initial_target = posixpath.join(posixpath.dirname(link_name), link_target)
        resolved_target = normalize_path(
            initial_target,
            "archive symlink escapes application",
        )
        if resolved_target != "CodexRadar.app" and not resolved_target.startswith("CodexRadar.app/"):
            reject("archive symlink escapes application")
        resolve_symlinks(resolved_target, symlinks, {link_name})
PYTHON
}

output_argument=""
signing_mode=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output)
      [[ -z "$output_argument" && "$#" -ge 2 ]] || usage
      output_argument="$2"
      shift 2
      ;;
    --signing-mode)
      [[ -z "$signing_mode" && "$#" -ge 2 ]] || usage
      signing_mode="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[[ -n "$output_argument" && -n "$signing_mode" ]] || usage
case "$signing_mode" in
  adhoc) ;;
  developer-id) validate_developer_id_inputs ;;
  *) die "signing-mode must be adhoc or developer-id" ;;
esac

load_version_config "$ROOT_DIR/version.env"
work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-release.XXXXXX")"
cleanup() {
  /bin/rm -rf "$work_dir" >/dev/null 2>&1 || true
}
handle_signal() {
  echo "release packaging interrupted" >&2
  exit 130
}
trap cleanup EXIT
trap handle_signal HUP INT TERM

DITTO_EXECUTABLE="${PACKAGE_RELEASE_DITTO_EXECUTABLE:-/usr/bin/ditto}"
PYTHON_EXECUTABLE="${PACKAGE_RELEASE_PYTHON_EXECUTABLE:-/usr/bin/python3}"
[[ -x "$DITTO_EXECUTABLE" ]] || die "ditto is required"
[[ -x "$PYTHON_EXECUTABLE" ]] || die "python3 is required for archive preflight"

package_dir="$work_dir/package"
extract_dir="$work_dir/extracted"
/bin/mkdir -m 700 "$package_dir" "$extract_dir"
app_path="$package_dir/$APP_NAME.app"

"$ROOT_DIR/script/package_app.sh" \
  --output "$package_dir" \
  --configuration release \
  --architectures "arm64 x86_64" \
  --updates-enabled true
"$ROOT_DIR/script/sign_app.sh" --app "$app_path" --signing-mode "$signing_mode"

if [[ "$signing_mode" == developer-id ]]; then
  notarization_archive="$work_dir/notarization.zip"
  "$DITTO_EXECUTABLE" -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$app_path" "$notarization_archive"
  /usr/bin/xcrun notarytool submit "$notarization_archive" \
    --key "$APP_STORE_CONNECT_API_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  /usr/bin/xcrun stapler staple "$app_path"
fi

"$ROOT_DIR/script/verify_app.sh" \
  --app "$app_path" \
  --architectures "arm64 x86_64" \
  --updates-enabled true \
  --signing-mode "$signing_mode"

archive_name="$(release_asset_basename).zip"
staged_archive="$work_dir/$archive_name"
"$DITTO_EXECUTABLE" -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$app_path" "$staged_archive"
preflight_archive "$staged_archive"
"$DITTO_EXECUTABLE" -x -k "$staged_archive" "$extract_dir"

extracted_entries=()
while IFS= read -r -d '' entry_path; do
  extracted_entries+=("$entry_path")
done < <(/usr/bin/find -s "$extract_dir" -mindepth 1 -maxdepth 1 -print0)
[[ "${#extracted_entries[@]}" -eq 1 && \
  "${extracted_entries[0]}" == "$extract_dir/$APP_NAME.app" && \
  -d "${extracted_entries[0]}" && ! -L "${extracted_entries[0]}" ]] ||
  die "extracted archive must contain exactly $APP_NAME.app"
"$ROOT_DIR/script/verify_app.sh" \
  --app "$extract_dir/$APP_NAME.app" \
  --architectures "arm64 x86_64" \
  --updates-enabled true \
  --signing-mode "$signing_mode"

output_parent="$(/usr/bin/dirname "$output_argument")"
output_name="$(/usr/bin/basename "$output_argument")"
/bin/mkdir -p "$output_parent"
output_parent_real="$(/bin/realpath "$output_parent")"
output_path="$output_parent_real/$output_name"
[[ ! -L "$output_path" ]] || die "release output directory must not be a symlink"
if [[ ! -e "$output_path" ]]; then
  /bin/mkdir "$output_path"
fi
[[ -d "$output_path" && ! -L "$output_path" ]] ||
  die "release output path must be a real directory"
output_path="$(/bin/realpath "$output_path")"

archive_path="$output_path/$archive_name"
checksum_path="$archive_path.sha256"
manifest_path="$archive_path.manifest"
for artifact_path in "$archive_path" "$checksum_path" "$manifest_path"; do
  [[ ! -e "$artifact_path" && ! -L "$artifact_path" ]] ||
    die "release artifact already exists: $artifact_path"
done

archive_sha256="$(/usr/bin/shasum -a 256 "$staged_archive" | /usr/bin/awk '{print $1}')"
archive_byte_length="$(/usr/bin/stat -f '%z' "$staged_archive")"
staged_checksum="$work_dir/$archive_name.sha256"
staged_manifest="$work_dir/$archive_name.manifest"
printf '%s  %s\n' "$archive_sha256" "$archive_path" >"$staged_checksum"
{
  printf 'archive_name=%s\n' "$archive_name"
  printf 'version=%s\n' "$MARKETING_VERSION"
  printf 'build=%s\n' "$BUILD_NUMBER"
  printf 'byte_length=%s\n' "$archive_byte_length"
  printf 'sha256=%s\n' "$archive_sha256"
  printf 'signing_mode=%s\n' "$signing_mode"
  if [[ "$signing_mode" == adhoc ]]; then
    printf 'distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted\n'
  else
    printf 'distribution_trust=developer-id-notarized\n'
  fi
} >"$staged_manifest"

/bin/mv "$staged_archive" "$archive_path"
/bin/mv "$staged_checksum" "$checksum_path"
/bin/mv "$staged_manifest" "$manifest_path"
trap - HUP INT TERM

if [[ "$signing_mode" == adhoc ]]; then
  printf '%s is locally signed with an ad-hoc identity; it is not Developer ID signed, notarized, or Gatekeeper-trusted.\n' \
    "$archive_name"
fi
printf 'Created %s\n' "$archive_path"
