#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_SCRIPT="$ROOT_DIR/script/test.sh"
README_FILE="$ROOT_DIR/README.md"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
CANDIDATE_WORKFLOW="$ROOT_DIR/.github/workflows/prepare-candidate.yml"
APPKIT_TEST_SUITES='MenuActionLayoutTests|MenuBarControllerTests|MenuBarPanelActionsTests|SettingsWindowBridgeTests'

fail() {
  echo "$*" >&2
  exit 1
}

[[ -x "$TEST_SCRIPT" ]] || fail "script/test.sh does not exist or is not executable"

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-test-entrypoint.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

mock_bin="$fixture_dir/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/swift" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${TEST_SWIFT_LOG:?}"
: "${TEST_SWIFT_COUNT:?}"

invocation_count=0
if [[ -f "$TEST_SWIFT_COUNT" ]]; then
  invocation_count="$(<"$TEST_SWIFT_COUNT")"
fi
invocation_count=$((invocation_count + 1))
printf '%s\n' "$invocation_count" >"$TEST_SWIFT_COUNT"

{
  printf 'cwd=%s\n' "$PWD"
  printf 'arg=%s\n' "$@"
} >>"$TEST_SWIFT_LOG"

if [[ "${TEST_SWIFT_FAIL_ON:-}" == "$invocation_count" ]]; then
  exit "${TEST_SWIFT_FAIL_CODE:-1}"
fi
MOCK
chmod +x "$mock_bin/swift"

swift_log="$fixture_dir/swift.log"
swift_count="$fixture_dir/swift.count"

reset_mock() {
  rm -f "$swift_log" "$swift_count"
}

run_entrypoint() {
  PATH="$mock_bin:$PATH" \
    TEST_SWIFT_LOG="$swift_log" \
    TEST_SWIFT_COUNT="$swift_count" \
    "$@"
}

assert_successful_sequence() {
  local expected_log="$fixture_dir/expected.log"
  cat >"$expected_log" <<EXPECTED
cwd=$ROOT_DIR
arg=test
arg=--no-parallel
arg=--filter
arg=$APPKIT_TEST_SUITES
cwd=$ROOT_DIR
arg=test
arg=--no-parallel
arg=--skip
arg=$APPKIT_TEST_SUITES
EXPECTED
  cmp -s "$expected_log" "$swift_log" || {
    diff -u "$expected_log" "$swift_log" >&2 || true
    fail "test entrypoint did not preserve the two-stage Swift arguments"
  }
}

reset_mock
run_entrypoint "$TEST_SCRIPT"
assert_successful_sequence

usage_output="$fixture_dir/usage-output"
reset_mock
set +e
run_entrypoint "$TEST_SCRIPT" --filter ExampleTests >"$usage_output" 2>&1
usage_status=$?
set -e
[[ "$usage_status" == 64 ]] || fail "unexpected arguments must exit with status 64"
[[ ! -e "$swift_log" ]] || fail "unexpected arguments invoked Swift"
grep -Fx "usage: ./script/test.sh" "$usage_output" >/dev/null ||
  fail "unexpected arguments did not report the supported invocation"

reset_mock
set +e
TEST_SWIFT_FAIL_ON=1 TEST_SWIFT_FAIL_CODE=17 run_entrypoint "$TEST_SCRIPT"
first_stage_status=$?
set -e
[[ "$first_stage_status" == 17 ]] || fail "first-stage failure status was not preserved"
[[ "$(<"$swift_count")" == 1 ]] || fail "second stage ran after first-stage failure"

reset_mock
set +e
TEST_SWIFT_FAIL_ON=2 TEST_SWIFT_FAIL_CODE=23 run_entrypoint "$TEST_SCRIPT"
second_stage_status=$?
set -e
[[ "$second_stage_status" == 23 ]] || fail "second-stage failure status was not preserved"
[[ "$(<"$swift_count")" == 2 ]] || fail "second-stage failure did not run both stages"

spaced_root="$fixture_dir/repository with spaces"
mkdir -p "$spaced_root/script"
cp "$TEST_SCRIPT" "$spaced_root/script/test.sh"
chmod +x "$spaced_root/script/test.sh"
spaced_root="$(cd "$spaced_root" && pwd)"
reset_mock
run_entrypoint "$spaced_root/script/test.sh"
grep -Fx "cwd=$spaced_root" "$swift_log" >/dev/null ||
  fail "test entrypoint did not safely resolve a repository path containing spaces"

assert_normative_caller() {
  local path="$1"
  local entrypoint_count

  entrypoint_count="$(grep -F -c './script/test.sh' "$path" || true)"
  [[ "$entrypoint_count" == 1 ]] ||
    fail "$path must reference ./script/test.sh exactly once"
  if grep -E 'swift[[:space:]]+test|--no-parallel|appkit_test_suites' "$path" >/dev/null; then
    fail "$path duplicates Swift test orchestration"
  fi
}

assert_normative_caller "$README_FILE"
assert_normative_caller "$CI_WORKFLOW"
assert_normative_caller "$CANDIDATE_WORKFLOW"
