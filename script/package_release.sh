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
import os
import stat
import struct
import sys
import unicodedata
import zipfile


APPLICATION_ROOT = "CodexRadar.app"
MAX_ARCHIVE_BYTE_LENGTH = 192 * 1024 * 1024
MAX_COMPRESSION_RATIO = 100
MAX_ENTRY_COUNT = 2048
MAX_ENTRY_UNCOMPRESSED_SIZE = 64 * 1024 * 1024
MAX_SYMLINK_PAYLOAD_SIZE = 4096
MAX_TOTAL_COMPRESSED_SIZE = 64 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED_SIZE = 128 * 1024 * 1024


def reject(message):
    raise SystemExit(message)


def normalize_archive_path(path):
    if not path or "\\" in path or "\x00" in path or path.startswith("/"):
        reject("archive contains an unsafe path")
    components = path.rstrip("/").split("/")
    if any(component in ("", ".", "..") for component in components):
        reject("archive contains an unsafe path")
    return components


def path_key(components):
    return tuple(
        unicodedata.normalize("NFC", component).casefold()
        for component in components
    )


def normalize_symlink_target(link_components, target):
    if not target or "\\" in target or "\x00" in target or target.startswith("/"):
        reject("archive contains an invalid symlink")
    normalized = []
    for component in list(link_components[:-1]) + target.split("/"):
        if component in ("", "."):
            continue
        if component == "..":
            if len(normalized) <= 1:
                reject("archive symlink escapes application")
            normalized.pop()
        else:
            normalized.append(component)
    if not normalized or path_key(normalized[:1]) != path_key([APPLICATION_ROOT]):
        reject("archive symlink escapes application")
    return normalized


def validate_local_data_ranges(archive, entries):
    ranges = []
    records = []
    archive_size = os.fstat(archive.fp.fileno()).st_size
    data_limit = min(archive.start_dir, archive_size)
    for entry in entries:
        if entry.header_offset < 0 or entry.header_offset + 30 > data_limit:
            reject("archive contains an invalid local data range")
        archive.fp.seek(entry.header_offset)
        local_header = archive.fp.read(30)
        if len(local_header) != 30:
            reject("archive contains an invalid local data range")
        (
            signature,
            _version,
            local_flags,
            local_method,
            _modified_time,
            _modified_date,
            local_crc,
            local_compressed_size,
            local_uncompressed_size,
            name_length,
            extra_length,
        ) = struct.unpack("<IHHHHHIIIHH", local_header)
        if signature != 0x04034B50:
            reject("archive contains an invalid local data range")
        data_start = entry.header_offset + 30 + name_length + extra_length
        data_end = data_start + entry.compress_size
        if data_start > data_limit or data_end > data_limit:
            reject("archive contains an invalid local data range")
        if local_flags & 0x8:
            archive.fp.seek(data_end)
            descriptor = archive.fp.read(min(24, data_limit - data_end))
            descriptor_offset = 4 if descriptor.startswith(b"PK\x07\x08") else 0
            descriptor_length = 0
            if len(descriptor) >= descriptor_offset + 12:
                crc, compressed_size, uncompressed_size = struct.unpack_from(
                    "<III", descriptor, descriptor_offset
                )
                if (
                    crc == entry.CRC
                    and compressed_size == entry.compress_size
                    and uncompressed_size == entry.file_size
                ):
                    descriptor_length = descriptor_offset + 12
            if descriptor_length == 0 and len(descriptor) >= descriptor_offset + 20:
                crc, compressed_size, uncompressed_size = struct.unpack_from(
                    "<IQQ", descriptor, descriptor_offset
                )
                if (
                    crc == entry.CRC
                    and compressed_size == entry.compress_size
                    and uncompressed_size == entry.file_size
                ):
                    descriptor_length = descriptor_offset + 20
            if descriptor_length == 0:
                reject("archive contains an invalid local header")
            data_end += descriptor_length
            if data_end > data_limit:
                reject("archive contains an invalid local data range")
        ranges.append((entry.header_offset, data_end))
        records.append(
            (
                entry,
                local_flags,
                local_method,
                local_crc,
                local_compressed_size,
                local_uncompressed_size,
                name_length,
            )
        )

    ranges.sort()
    for previous, current in zip(ranges, ranges[1:]):
        if current[0] < previous[1]:
            reject("archive contains overlapping local data ranges")

    for (
        entry,
        local_flags,
        local_method,
        local_crc,
        local_compressed_size,
        local_uncompressed_size,
        name_length,
    ) in records:
        archive.fp.seek(entry.header_offset + 30)
        local_name_bytes = archive.fp.read(name_length)
        try:
            encoding = "utf-8" if local_flags & 0x800 else "cp437"
            local_name = local_name_bytes.decode(encoding)
        except UnicodeDecodeError:
            reject("archive contains an invalid local header")
        if (
            local_name != entry.filename
            or local_flags != entry.flag_bits
            or local_method != entry.compress_type
        ):
            reject("archive contains an invalid local header")
        if local_flags & 0x8:
            size_values_are_valid = (
                local_crc in (0, entry.CRC)
                and local_compressed_size in (0, entry.compress_size)
                and local_uncompressed_size in (0, entry.file_size)
            )
        else:
            size_values_are_valid = (
                local_crc == entry.CRC
                and local_compressed_size == entry.compress_size
                and local_uncompressed_size == entry.file_size
            )
        if not size_values_are_valid:
            reject("archive contains an invalid local header")


def resolve_symlinks(components, entries_by_key, symlinks, seen=None):
    seen = set() if seen is None else seen
    for index in range(1, len(components) + 1):
        prefix_key = path_key(components[:index])
        if prefix_key not in symlinks:
            continue
        if prefix_key in seen:
            reject("archive contains an unsafe symlink cycle")
        link_components, target = symlinks[prefix_key]
        resolved_components = normalize_symlink_target(link_components, target)
        resolved_components.extend(components[index:])
        return resolve_symlinks(
            resolved_components,
            entries_by_key,
            symlinks,
            seen | {prefix_key},
        )
    resolved_key = path_key(components)
    if resolved_key not in entries_by_key:
        reject("archive symlink target is missing")
    return resolved_key


archive_path = sys.argv[1]
try:
    archive_status = os.stat(archive_path, follow_symlinks=False)
except OSError as error:
    reject("invalid release archive: {}".format(error))
if not stat.S_ISREG(archive_status.st_mode):
    reject("release archive must be a regular file")
if archive_status.st_size > MAX_ARCHIVE_BYTE_LENGTH:
    reject("release archive exceeds byte length limit")

try:
    archive = zipfile.ZipFile(archive_path)
except (OSError, zipfile.BadZipFile) as error:
    reject("invalid release archive: {}".format(error))

with archive:
    entries = archive.infolist()
    if not entries:
        reject("release archive is empty")
    if len(entries) > MAX_ENTRY_COUNT:
        reject("archive contains too many entries")

    total_compressed_size = 0
    total_uncompressed_size = 0
    for entry in entries:
        if entry.file_size > MAX_ENTRY_UNCOMPRESSED_SIZE:
            reject("archive entry exceeds uncompressed size limit")
        total_uncompressed_size += entry.file_size
        total_compressed_size += entry.compress_size
        if total_uncompressed_size > MAX_TOTAL_UNCOMPRESSED_SIZE:
            reject("archive exceeds total uncompressed size limit")
        if entry.file_size > 0 and (
            entry.compress_size == 0
            or entry.file_size > entry.compress_size * MAX_COMPRESSION_RATIO
        ):
            reject("archive entry exceeds compression ratio limit")
    if total_compressed_size > MAX_TOTAL_COMPRESSED_SIZE:
        reject("archive exceeds cumulative compressed size limit")

    validate_local_data_ranges(archive, entries)

    entries_by_key = {}
    entry_types = {}
    symlinks = {}
    for entry in entries:
        name = entry.filename
        components = normalize_archive_path(name)
        if any(component == "__MACOSX" or component.startswith("._") for component in components):
            reject("archive contains AppleDouble metadata")
        if components[0] != APPLICATION_ROOT:
            reject("archive contains an unexpected top-level entry")
        normalized_name = "/".join(components)
        key = path_key(components)
        if key in entries_by_key:
            if entries_by_key[key][0] == normalized_name:
                reject("archive contains duplicate entries")
            reject("archive contains a macOS path collision")
        entries_by_key[key] = (normalized_name, components, entry)
        if entry.flag_bits & 0x1:
            reject("archive contains an encrypted entry")

        file_type = (entry.external_attr >> 16) & stat.S_IFMT(0o177777)
        if file_type == stat.S_IFLNK:
            entry_types[key] = "symlink"
            if entry.file_size > MAX_SYMLINK_PAYLOAD_SIZE:
                reject("archive symlink payload is too large")
        elif file_type == stat.S_IFDIR or (file_type == 0 and entry.is_dir()):
            entry_types[key] = "directory"
        elif file_type in (0, stat.S_IFREG):
            entry_types[key] = "file"
        else:
            reject("archive contains an unsupported entry type")

    root_key = path_key([APPLICATION_ROOT])
    if root_key not in entries_by_key:
        reject("archive does not contain the application root")
    if entry_types[root_key] != "directory":
        reject("archive application root must be a directory")

    for key, (_name, components, _entry) in entries_by_key.items():
        for component_count in range(1, len(components)):
            ancestor_key = path_key(components[:component_count])
            ancestor_type = entry_types.get(ancestor_key)
            if ancestor_type == "symlink":
                reject("archive entry is nested beneath a symlink")
            if ancestor_type not in (None, "directory"):
                reject("archive contains a file-directory ancestry conflict")

    for key, (_name, components, entry) in entries_by_key.items():
        if entry_types[key] != "symlink":
            continue
        try:
            target_bytes = archive.read(entry)
            target = target_bytes.decode("utf-8")
        except (KeyError, OSError, RuntimeError, UnicodeDecodeError, zipfile.BadZipFile):
            reject("archive contains an invalid symlink")
        if len(target_bytes) > MAX_SYMLINK_PAYLOAD_SIZE:
            reject("archive symlink payload is too large")
        normalize_symlink_target(components, target)
        symlinks[key] = (components, target)

    for key, (components, target) in symlinks.items():
        target_components = normalize_symlink_target(components, target)
        resolve_symlinks(target_components, entries_by_key, symlinks, {key})
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
atomic_swap_executable="$work_dir/atomic-swap"
output_path=""
output_device=""
output_inode=""
publish_stage=""
publish_stage_name=""
publish_stage_device=""
publish_stage_inode=""
lock_process_id=""
lock_pipe_open=false
publication_committed=false
publication_in_flight=false
pending_release_signal=""
published_names=()
published_devices=()
published_inodes=()
cleanup() {
  local published_index

  set +e
  if [[ "$publication_committed" == false && -x "$atomic_swap_executable" && \
    -n "$output_path" && -n "$output_device" && -n "$output_inode" ]]; then
    published_index="${#published_names[@]}"
    while [[ "$published_index" -gt 0 ]]; do
      published_index=$((published_index - 1))
      "$atomic_swap_executable" remove-file "$output_path" \
        "${published_names[$published_index]}" "$output_device" "$output_inode" \
        "${published_devices[$published_index]}" "${published_inodes[$published_index]}" \
        >/dev/null 2>&1 || true
    done
  fi
  if [[ -x "$atomic_swap_executable" && -n "$publish_stage" && \
    -d "$publish_stage" && ! -L "$publish_stage" ]]; then
    "$atomic_swap_executable" remove "$output_path" "$publish_stage_name" \
      "$output_device" "$output_inode" "$publish_stage_device" \
      "$publish_stage_inode" >/dev/null 2>&1 || true
  fi
  if [[ "$lock_pipe_open" == true ]]; then
    exec 9>&-
    lock_pipe_open=false
  fi
  [[ -z "$lock_process_id" ]] || wait "$lock_process_id" >/dev/null 2>&1 || true
  /bin/rm -rf "$work_dir" >/dev/null 2>&1 || true
  return 0
}
handle_release_signal() {
  local signal_name="$1"

  [[ -n "$pending_release_signal" ]] || pending_release_signal="$signal_name"
  if [[ "$publication_in_flight" != true ]]; then
    echo "release publishing interrupted" >&2
    exit 130
  fi
  return 0
}
pause_after_release_lock_for_test() {
  local control_dir="${PACKAGE_RELEASE_TEST_CONTROL_DIR:-}"

  [[ "${PACKAGE_RELEASE_TEST_PAUSE_AFTER_LOCK:-false}" == true ]] || return 0
  [[ -n "$control_dir" && -d "$control_dir" && ! -L "$control_dir" ]] ||
    die "invalid release test control directory" || return 1
  : >"$control_dir/ready"
  while [[ ! -e "$control_dir/continue" ]]; do
    /bin/sleep 0.01
  done
}
trap cleanup EXIT
trap 'handle_release_signal HUP' HUP
trap 'handle_release_signal INT' INT
trap 'handle_release_signal TERM' TERM

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
if [[ -n "${PACKAGE_RELEASE_EXTRACT_MARKER:-}" ]]; then
  : >"$PACKAGE_RELEASE_EXTRACT_MARKER"
fi
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
[[ -n "$output_name" && "$output_name" != . && "$output_name" != .. ]] ||
  die "invalid release output directory name"
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
output_owner="$(/usr/bin/stat -f '%u' "$output_path")"
output_mode="$(/usr/bin/stat -f '%Lp' "$output_path")"
output_device="$(/usr/bin/stat -f '%d' "$output_path")"
output_inode="$(/usr/bin/stat -f '%i' "$output_path")"
[[ "$output_owner" == "$(/usr/bin/id -u)" ]] ||
  die "release output directory must be owned by the effective user"
(( (8#$output_mode & 022) == 0 )) ||
  die "release output directory must not be group or world writable"

atomic_swap_source="$ROOT_DIR/script/helpers/atomic_swap.c"
[[ -f "$atomic_swap_source" ]] || die "missing atomic swap helper source"
/usr/bin/xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
  -mmacosx-version-min="$MIN_SYSTEM_VERSION" "$atomic_swap_source" \
  -o "$atomic_swap_executable"

lock_fifo="$work_dir/release-lock.fifo"
lock_ready="$work_dir/release-lock.ready"
/usr/bin/mkfifo "$lock_fifo"
"$atomic_swap_executable" lock "$output_path" ".$APP_NAME.release.lock" \
  "$output_device" "$output_inode" <"$lock_fifo" >"$lock_ready" \
  2>"$work_dir/release-lock.stderr" &
lock_process_id=$!
exec 9>"$lock_fifo"
lock_pipe_open=true
lock_attempt=0
while [[ ! -s "$lock_ready" && "$lock_attempt" -lt 200 ]]; do
  if ! /bin/kill -0 "$lock_process_id" 2>/dev/null; then
    exec 9>&-
    lock_pipe_open=false
    wait "$lock_process_id" || true
    /bin/cat "$work_dir/release-lock.stderr" >&2
    die "failed to acquire release output lock"
  fi
  /bin/sleep 0.01
  lock_attempt=$((lock_attempt + 1))
done
[[ -s "$lock_ready" ]] || die "timed out acquiring release output lock"
pause_after_release_lock_for_test

archive_path="$output_path/$archive_name"
checksum_path="$archive_path.sha256"
manifest_path="$archive_path.manifest"
for artifact_path in "$archive_path" "$checksum_path" "$manifest_path"; do
  [[ ! -e "$artifact_path" && ! -L "$artifact_path" ]] ||
    die "release artifact already exists: $artifact_path"
done

publish_stage="$(/usr/bin/mktemp -d "$output_path/.$APP_NAME.release.stage.XXXXXX")"
/bin/chmod 700 "$publish_stage"
publish_stage_name="$(/usr/bin/basename "$publish_stage")"
publish_stage_device="$(/usr/bin/stat -f '%d' "$publish_stage")"
publish_stage_inode="$(/usr/bin/stat -f '%i' "$publish_stage")"
[[ "$publish_stage_device" == "$output_device" ]] ||
  die "release staging directory must be on the output filesystem"

staged_publish_archive="$publish_stage/$archive_name"
staged_checksum="$publish_stage/$archive_name.sha256"
staged_manifest="$publish_stage/$archive_name.manifest"
/bin/cp "$staged_archive" "$staged_publish_archive"
archive_sha256="$(/usr/bin/shasum -a 256 "$staged_publish_archive" | /usr/bin/awk '{print $1}')"
archive_byte_length="$(/usr/bin/stat -f '%z' "$staged_publish_archive")"
printf '%s  %s\n' "$archive_sha256" "$archive_name" >"$staged_checksum"
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

(
  cd "$publish_stage"
  /usr/bin/shasum -a 256 --check "$archive_name.sha256" >/dev/null
) || die "staged release checksum verification failed"

publish_sources=("$staged_publish_archive" "$staged_checksum" "$staged_manifest")
publish_destinations=("$archive_name" "$archive_name.sha256" "$archive_name.manifest")
publish_index=0
while [[ "$publish_index" -lt "${#publish_sources[@]}" ]]; do
  artifact_number=$((publish_index + 1))
  if [[ "${PACKAGE_RELEASE_TEST_FAIL_PUBLISH_INDEX:-}" == "$artifact_number" ]]; then
    die "injected release publish failure at artifact $artifact_number"
  fi
  publish_source="${publish_sources[$publish_index]}"
  publish_destination="${publish_destinations[$publish_index]}"
  publish_device="$(/usr/bin/stat -f '%d' "$publish_source")"
  publish_inode="$(/usr/bin/stat -f '%i' "$publish_source")"
  published_names+=("$publish_destination")
  published_devices+=("$publish_device")
  published_inodes+=("$publish_inode")
  publication_in_flight=true
  publish_status=0
  "$atomic_swap_executable" publish "$output_path" "$publish_stage_name" \
    "$publish_destination" "$publish_destination" "$output_device" \
    "$output_inode" "$publish_stage_device" "$publish_stage_inode" \
    "$publish_device" "$publish_inode" || publish_status=$?
  publication_in_flight=false
  if [[ -n "$pending_release_signal" ]]; then
    echo "release publishing interrupted" >&2
    exit 130
  fi
  [[ "$publish_status" -eq 0 ]] || die "release artifact publication failed"
  if [[ "${PACKAGE_RELEASE_TEST_SIGNAL_AFTER_PUBLISH_COUNT:-}" == "$artifact_number" ]]; then
    /bin/kill -TERM "$$"
  fi
  publish_index=$((publish_index + 1))
done

"$atomic_swap_executable" remove "$output_path" "$publish_stage_name" \
  "$output_device" "$output_inode" "$publish_stage_device" "$publish_stage_inode"
publish_stage=""
publication_committed=true
exec 9>&-
lock_pipe_open=false
wait "$lock_process_id"
lock_process_id=""
trap - HUP INT TERM

if [[ "$signing_mode" == adhoc ]]; then
  printf '%s is locally signed with an ad-hoc identity; it is not Developer ID signed, notarized, or Gatekeeper-trusted.\n' \
    "$archive_name"
fi
printf 'Created %s\n' "$archive_path"
