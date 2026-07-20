#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="tangwz/codex-radar"
BRANCH="main"
FEED_PATH="appcast.xml"
RAW_FEED_URL="https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_update_artifacts.sh"
UPDATE_CONFIG="${HALT_TEST_UPDATE_CONFIG:-$ROOT_DIR/config/update.env}"
SPARKLE_SOURCE="${HALT_TEST_SPARKLE_SOURCE:-$ROOT_DIR/.build/checkouts/Sparkle}"
GH_EXECUTABLE="${HALT_GH_EXECUTABLE:-gh}"
HTTP_EXECUTABLE="${HALT_HTTP_EXECUTABLE:-/usr/bin/curl}"
POLL_ATTEMPTS="${HALT_TEST_POLL_ATTEMPTS:-12}"
POLL_INTERVAL_SECONDS="${HALT_TEST_POLL_INTERVAL_SECONDS:-5}"

usage() {
  echo "usage: $0 --previous-commit COMMIT" >&2
  return 2
}

die() {
  echo "$*" >&2
  return 1
}

previous_commit=""
if [[ "$#" -eq 2 && "$1" == --previous-commit ]]; then
  previous_commit="$2"
else
  usage
fi

[[ "$previous_commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "previous commit must be a full Git commit SHA" || exit 1
[[ "$POLL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "invalid halt poll attempts" || exit 1
[[ "$POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] ||
  die "invalid halt poll interval" || exit 1
command -v "$GH_EXECUTABLE" >/dev/null 2>&1 || die "gh executable is unavailable" || exit 1
command -v "$HTTP_EXECUTABLE" >/dev/null 2>&1 ||
  die "HTTP transport executable is unavailable" || exit 1
[[ -x "$VERIFY_SCRIPT" ]] || die "update verifier is unavailable" || exit 1

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-halt.XXXXXX")"
cleanup() {
  if [[ -d "$work_dir" && ! -L "$work_dir" ]]; then
    /bin/rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

decode_contents_response() {
  local response_path="$1" output_path="$2" sha_path="$3"

  /usr/bin/python3 - "$response_path" "$output_path" "$sha_path" <<'PYTHON'
import base64
import binascii
import json
import pathlib
import re
import sys

response_path, output_path, sha_path = map(pathlib.Path, sys.argv[1:])
try:
    response = json.loads(response_path.read_bytes())
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("invalid GitHub Contents API response: {}".format(error))
if not isinstance(response, dict) or response.get("type") != "file":
    raise SystemExit("GitHub Contents API response is not a file")
sha = response.get("sha")
content = response.get("content")
if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
    raise SystemExit("GitHub Contents API response has an invalid blob SHA")
if response.get("encoding") != "base64" or not isinstance(content, str):
    raise SystemExit("GitHub Contents API response has invalid content encoding")
try:
    encoded = "".join(content.split()).encode("ascii")
    decoded = base64.b64decode(encoded, validate=True)
except (UnicodeEncodeError, binascii.Error) as error:
    raise SystemExit("GitHub Contents API response has invalid base64 content: {}".format(error))
output_path.write_bytes(decoded)
sha_path.write_text(sha + "\n", encoding="ascii")
PYTHON
}

fetch_contents() {
  local ref="$1" response_path="$2" output_path="$3" sha_path="$4"

  "$GH_EXECUTABLE" api --method GET \
    "repos/$REPOSITORY/contents/$FEED_PATH?ref=$ref" >"$response_path" || return 1
  decode_contents_response "$response_path" "$output_path" "$sha_path"
}

parse_latest_feed_parent() {
  local response_path="$1" parent_path="$2"

  /usr/bin/python3 - "$response_path" "$parent_path" <<'PYTHON'
import json
import pathlib
import re
import sys

response_path, parent_path = map(pathlib.Path, sys.argv[1:])
try:
    response = json.loads(response_path.read_bytes())
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("invalid commit history response: {}".format(error))
if not isinstance(response, list) or len(response) != 1:
    raise SystemExit("commit history response must contain exactly one commit")
commit = response[0]
if not isinstance(commit, dict):
    raise SystemExit("commit history entry must be an object")
commit_sha = commit.get("sha")
parents = commit.get("parents")
if not isinstance(commit_sha, str) or re.fullmatch(r"[0-9a-f]{40}", commit_sha) is None:
    raise SystemExit("commit history entry has an invalid SHA")
if not isinstance(parents, list) or not parents or not isinstance(parents[0], dict):
    raise SystemExit("commit history entry is missing its first parent")
parent_sha = parents[0].get("sha")
if not isinstance(parent_sha, str) or re.fullmatch(r"[0-9a-f]{40}", parent_sha) is None:
    raise SystemExit("commit history first parent has an invalid SHA")
if parent_sha == commit_sha:
    raise SystemExit("commit history first parent must differ from the commit")
parent_path.write_text(parent_sha + "\n", encoding="ascii")
PYTHON
}

"$GH_EXECUTABLE" auth status >/dev/null 2>&1 ||
  die "an authenticated operator gh session is required" || exit 1

current_response="$work_dir/current-response.json"
current_feed="$work_dir/current-appcast.xml"
current_sha_path="$work_dir/current-blob-sha"
fetch_contents "$BRANCH" "$current_response" "$current_feed" "$current_sha_path" ||
  die "unable to fetch current Production Feed" || exit 1
current_blob_sha="$(<"$current_sha_path")"

previous_response="$work_dir/previous-response.json"
previous_feed="$work_dir/previous-appcast.xml"
previous_sha_path="$work_dir/previous-blob-sha"
fetch_contents "$previous_commit" "$previous_response" "$previous_feed" "$previous_sha_path" ||
  die "unable to fetch previous Production Feed from commit $previous_commit" || exit 1

intervening_feed=""
if /usr/bin/cmp -s "$current_feed" "$previous_feed"; then
  history_response="$work_dir/appcast-history.json"
  "$GH_EXECUTABLE" api --method GET \
    "repos/$REPOSITORY/commits?sha=$BRANCH&path=$FEED_PATH&per_page=1" >"$history_response" ||
    die "unable to fetch Production Feed commit history" || exit 1
  parent_sha_path="$work_dir/appcast-parent-sha"
  parse_latest_feed_parent "$history_response" "$parent_sha_path" ||
    die "invalid Production Feed commit history" || exit 1
  parent_sha="$(<"$parent_sha_path")"
  intervening_response="$work_dir/intervening-response.json"
  intervening_feed="$work_dir/intervening-appcast.xml"
  intervening_sha_path="$work_dir/intervening-blob-sha"
  fetch_contents "$parent_sha" "$intervening_response" "$intervening_feed" \
    "$intervening_sha_path" ||
    die "unable to fetch intervening Production Feed from commit $parent_sha" || exit 1
fi

verification_output="$work_dir/halt-verification"
verification_arguments=(
  --mode halt
  --current-feed "$current_feed"
  --previous-feed "$previous_feed"
  --update-config "$UPDATE_CONFIG"
  --sparkle-source "$SPARKLE_SOURCE"
)
if [[ -n "$intervening_feed" ]]; then
  verification_arguments+=(--intervening-feed "$intervening_feed")
fi
"$VERIFY_SCRIPT" "${verification_arguments[@]}" >"$verification_output"

current_tag=""
current_version=""
current_build=""
previous_version=""
previous_build=""
halt_state=""
while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
  case "$key" in
    halt_state)
      [[ -z "$halt_state" ]] || die "duplicate halt_state from halt verifier" || exit 1
      halt_state="$value"
      ;;
    current_tag)
      [[ -z "$current_tag" ]] || die "duplicate current_tag from halt verifier" || exit 1
      current_tag="$value"
      ;;
    current_version)
      [[ -z "$current_version" ]] || die "duplicate current_version from halt verifier" || exit 1
      current_version="$value"
      ;;
    current_build)
      [[ -z "$current_build" ]] || die "duplicate current_build from halt verifier" || exit 1
      current_build="$value"
      ;;
    previous_version)
      [[ -z "$previous_version" ]] || die "duplicate previous_version from halt verifier" || exit 1
      previous_version="$value"
      ;;
    previous_build)
      [[ -z "$previous_build" ]] || die "duplicate previous_build from halt verifier" || exit 1
      previous_build="$value"
      ;;
    *) die "unexpected halt verifier output" || exit 1 ;;
  esac
done <"$verification_output"
[[ "$halt_state" == ready || "$halt_state" == already-halted ]] ||
  die "halt verifier returned an invalid state" || exit 1
[[ "$current_tag" == "v$current_version" && "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && \
  "$current_build" =~ ^[1-9][0-9]*$ && "$previous_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && \
  "$previous_build" =~ ^[1-9][0-9]*$ ]] ||
  die "halt verifier returned incomplete metadata" || exit 1

current_sha256="$(/usr/bin/shasum -a 256 "$current_feed" | /usr/bin/awk '{print $1}')"
previous_sha256="$(/usr/bin/shasum -a 256 "$previous_feed" | /usr/bin/awk '{print $1}')"
printf 'Current Production Feed: %s (%s), SHA-256 %s\n' \
  "$current_version" "$current_build" "$current_sha256"
printf 'Previous Production Feed: %s (%s), SHA-256 %s\n' \
  "$previous_version" "$previous_build" "$previous_sha256"
if [[ "$halt_state" == ready ]]; then
  printf 'Type %s to replace the Production Feed with the exact previous signed bytes: ' \
    "$current_tag" >&2
  confirmation=""
  IFS= read -r confirmation || true
  [[ "$confirmation" == "$current_tag" ]] ||
    die "confirmation did not match current tag $current_tag" || exit 1

  payload_path="$work_dir/put-payload.json"
  /usr/bin/python3 - "$previous_feed" "$current_blob_sha" "$BRANCH" >"$payload_path" <<'PYTHON'
import base64
import json
import pathlib
import sys

feed_path = pathlib.Path(sys.argv[1])
print(json.dumps({
    "message": "ops: halt update distribution",
    "content": base64.b64encode(feed_path.read_bytes()).decode("ascii"),
    "sha": sys.argv[2],
    "branch": sys.argv[3],
}, separators=(",", ":")))
PYTHON

  put_response="$work_dir/put-response"
  set +e
  "$GH_EXECUTABLE" api --include --method PUT \
    "repos/$REPOSITORY/contents/$FEED_PATH" --input "$payload_path" >"$put_response"
  put_status=$?
  set -e
  http_status="$(/usr/bin/sed -nE 's/^HTTP\/[^ ]+ ([0-9]{3}).*/\1/p' "$put_response" | \
    /usr/bin/tail -n 1)"
  if [[ "$http_status" == 409 || "$http_status" == 422 ]]; then
    die "CAS conflict while writing Production Feed (HTTP $http_status)" || exit 1
  fi
  if [[ "$put_status" -ne 0 || ! "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    die "unable to write halted Production Feed" || exit 1
  fi
else
  printf 'Distribution Halt is already present in the repository; resuming verification without another PUT.\n'
fi

repository_response="$work_dir/repository-response.json"
repository_feed="$work_dir/repository-appcast.xml"
repository_sha_path="$work_dir/repository-blob-sha"
fetch_contents "$BRANCH" "$repository_response" "$repository_feed" "$repository_sha_path" ||
  die "unable to re-fetch repository Production Feed after Distribution Halt PUT" || exit 1
/usr/bin/cmp -s "$repository_feed" "$previous_feed" ||
  die "repository Production Feed bytes differ after Distribution Halt PUT" || exit 1

raw_feed="$work_dir/raw-appcast.xml"
retry_feed="$current_feed"
if [[ "$halt_state" == already-halted ]]; then
  [[ -n "$intervening_feed" ]] || die "already-halted state lacks provenance feed" || exit 1
  retry_feed="$intervening_feed"
fi
for ((attempt = 1; attempt <= POLL_ATTEMPTS; attempt++)); do
  : >"$raw_feed"
  if "$HTTP_EXECUTABLE" --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 "$RAW_FEED_URL" >"$raw_feed"; then
    if /usr/bin/cmp -s "$raw_feed" "$previous_feed"; then
      printf 'Distribution Halt completed: Production Feed now serves %s (%s).\n' \
        "$previous_version" "$previous_build"
      printf 'Note: already-upgraded installations are not downgraded; publish a higher-version repair when needed.\n'
      exit 0
    fi
    /usr/bin/cmp -s "$raw_feed" "$retry_feed" ||
      die "raw Production Feed returned unknown bytes" || exit 1
  fi
  if [[ "$attempt" -lt "$POLL_ATTEMPTS" && "$POLL_INTERVAL_SECONDS" -gt 0 ]]; then
    /bin/sleep "$POLL_INTERVAL_SECONDS"
  fi
done

die "Distribution Halt Pending: repository bytes are correct but the fixed raw URL did not converge" || exit 1
