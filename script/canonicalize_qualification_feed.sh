#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

usage() {
  cat >&2 <<EOF
usage: $0 --feed PATH --archive-name NAME
EOF
  return 2
}

feed_path=""
archive_name=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --feed)
      [[ "$#" -ge 2 ]] || usage
      feed_path="$2"
      shift 2
      ;;
    --archive-name)
      [[ "$#" -ge 2 ]] || usage
      archive_name="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$feed_path" && -n "$archive_name" ]] || usage
[[ "$archive_name" =~ ^[A-Za-z0-9._-]+\.zip$ && "$archive_name" != .* ]] ||
  die "invalid qualification archive name"
[[ -f "$feed_path" && ! -L "$feed_path" ]] ||
  die "qualification feed must be a real file"

feed_parent="$(cd "$(/usr/bin/dirname "$feed_path")" && pwd -P)"
[[ -d "$feed_parent" && ! -L "$feed_parent" ]] ||
  die "qualification feed parent must be a real directory"
feed_path="$feed_parent/$(/usr/bin/basename "$feed_path")"

total_length="$(/usr/bin/stat -f '%z' "$feed_path")"
[[ "$total_length" =~ ^[1-9][0-9]*$ && "$total_length" -le 8388608 ]] ||
  die "qualification feed exceeds the size limit"

signature_line="$(/usr/bin/tail -n 3 "$feed_path" | /usr/bin/sed -n '1p')"
length_line="$(/usr/bin/tail -n 3 "$feed_path" | /usr/bin/sed -n '2p')"
final_line="$(/usr/bin/tail -n 3 "$feed_path" | /usr/bin/sed -n '3p')"
[[ "$final_line" == '-->' && "$signature_line" == 'edSignature: '* &&
  "$length_line" == 'length: '* ]] ||
  die "qualification feed has an invalid signature block"
signature="${signature_line#edSignature: }"
signed_length="${length_line#length: }"
[[ "$signed_length" =~ ^[1-9][0-9]*$ && "$signed_length" -le "$total_length" ]] ||
  die "qualification feed has an invalid signature block"

work_dir="$(/usr/bin/mktemp -d "$feed_parent/.canonicalize-feed.XXXXXX")"
cleanup() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" && ! -L "$work_dir" ]]; then
    /bin/rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

content_path="$work_dir/appcast.xml"
block_path="$work_dir/signature-block"
expected_block="$work_dir/expected-signature-block"
/bin/dd if="$feed_path" of="$content_path" bs=1 count="$signed_length" 2>/dev/null ||
  die "unable to extract qualification feed content"
printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
  "$signature" "$signed_length" >"$expected_block"
block_length="$(/usr/bin/stat -f '%z' "$expected_block")"
[[ "$total_length" == "$((signed_length + block_length))" ]] ||
  die "qualification feed has an invalid signature block"
/bin/dd if="$feed_path" of="$block_path" bs=1 skip="$signed_length" 2>/dev/null ||
  die "unable to extract qualification feed signature block"
/usr/bin/cmp -s "$expected_block" "$block_path" ||
  die "qualification feed has an invalid signature block"

if LC_ALL=C /usr/bin/grep -a -F '<!DOCTYPE' "$content_path" >/dev/null; then
  die "qualification feed must not contain a document type declaration"
fi
/usr/bin/xmllint --nonet --noout "$content_path" >/dev/null 2>&1 ||
  die "qualification feed is not valid XML"
enclosure="/*[local-name()='rss' and namespace-uri()='']/*[local-name()='channel' and namespace-uri()='']/*[local-name()='item' and namespace-uri()='']/*[local-name()='enclosure' and namespace-uri()='']"
[[ "$(/usr/bin/xmllint --nonet --xpath "count($enclosure/@url)" "$content_path" 2>/dev/null)" == 1 ]] ||
  die "qualification feed must contain exactly one enclosure URL"
enclosure_url="$(/usr/bin/xmllint --nonet --xpath "string($enclosure/@url)" "$content_path" 2>/dev/null)"

case "$enclosure_url" in
  "$archive_name")
    ;;
  "//$archive_name")
    /usr/bin/ruby - "$content_path" "$archive_name" <<'RUBY'
path, archive_name = ARGV
content = File.binread(path)
source = %(url="//#{archive_name}")
replacement = %(url="#{archive_name}")
abort("qualification feed URL bytes are ambiguous") unless content.scan(source).length == 1
File.binwrite(path, content.sub(source, replacement))
RUBY
    ;;
  *)
    die "qualification feed has an unexpected enclosure URL"
    ;;
esac

/usr/bin/xmllint --nonet --noout "$content_path" >/dev/null 2>&1 ||
  die "canonical qualification feed is not valid XML"
canonical_url="$(/usr/bin/xmllint --nonet --xpath "string($enclosure/@url)" "$content_path" 2>/dev/null)"
[[ "$canonical_url" == "$archive_name" ]] ||
  die "qualification feed URL canonicalization failed"

feed_mode="$(/usr/bin/stat -f '%Lp' "$feed_path")"
/bin/chmod "$feed_mode" "$content_path"
/bin/mv -f "$content_path" "$feed_path"
printf 'Canonicalized %s\n' "$feed_path"
