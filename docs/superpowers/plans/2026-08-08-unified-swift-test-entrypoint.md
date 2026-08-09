# Unified Swift Test Entrypoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide one repository-level command that runs the complete Swift test suite with the AppKit isolation required by local development, CI, and candidate preparation.

**Architecture:** Add a no-argument `script/test.sh` orchestrator that runs the four AppKit-facing suites in one serialized Swift Testing process, then runs all remaining suites in a second serialized process. Keep release-chain shell tests outside this Swift-specific entrypoint, and make README plus both workflows delegate only the Swift test phase to it.

**Tech Stack:** Bash, Swift Package Manager, Swift Testing, GitHub Actions YAML

## Global Constraints

- Preserve the existing AppKit suite regex and two-process execution order.
- The default no-argument invocation must run the complete Swift suite.
- Do not modify product APIs, stores, update contracts, signing, notarization, secrets, or production state.
- Keep the change reviewable and do not push or publish.

---

### Task 1: Define the entrypoint contract with failing tests

**Files:**
- Create: `Tests/ScriptTests/test_entrypoint_tests.sh`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`

**Interfaces:**
- Consumes: the intended `script/test.sh` executable and the current README/workflow files.
- Produces: a shell contract test that records every mock `swift` argument and validates all normative callers.

- [ ] **Step 1: Write the failing contract test**

Create a PATH-injected mock `swift` that records null-delimited arguments and supports deterministic failure on invocation one or two. Assert this exact successful sequence:

```text
test
--no-parallel
--filter
MenuActionLayoutTests|MenuBarControllerTests|MenuBarPanelActionsTests|SettingsWindowBridgeTests
test
--no-parallel
--skip
MenuActionLayoutTests|MenuBarControllerTests|MenuBarPanelActionsTests|SettingsWindowBridgeTests
```

Also assert that an unexpected argument is rejected before Swift runs, stage-one and stage-two exit codes are preserved, the script works from a copied repository path containing spaces, and README plus both workflows reference `./script/test.sh` without embedding `swift test`, `--no-parallel`, or `appkit_test_suites`.

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
bash Tests/ScriptTests/test_entrypoint_tests.sh
```

Expected: non-zero exit with `script/test.sh does not exist`, proving the repository has no unified entrypoint.

### Task 2: Implement the two-stage Swift test entrypoint

**Files:**
- Create: `script/test.sh`
- Test: `Tests/ScriptTests/test_entrypoint_tests.sh`

**Interfaces:**
- Consumes: no command-line arguments; `swift` resolved through `PATH`.
- Produces: exit zero only if both SwiftPM stages pass, otherwise the failing stage's exit status.

- [ ] **Step 1: Add the minimal orchestrator**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPKIT_TEST_SUITES='MenuActionLayoutTests|MenuBarControllerTests|MenuBarPanelActionsTests|SettingsWindowBridgeTests'

if (( $# != 0 )); then
  echo "usage: ./script/test.sh" >&2
  exit 64
fi

cd "$ROOT_DIR"

swift test --no-parallel --filter "$APPKIT_TEST_SUITES"
swift test --no-parallel --skip "$APPKIT_TEST_SUITES"
```

- [ ] **Step 2: Make the entrypoint executable and verify GREEN**

Run:

```bash
chmod +x script/test.sh Tests/ScriptTests/test_entrypoint_tests.sh
bash Tests/ScriptTests/test_entrypoint_tests.sh
```

Expected: exit zero with no failed assertions.

### Task 3: Converge normative callers

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/prepare-candidate.yml`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`
- Test: `Tests/ScriptTests/test_entrypoint_tests.sh`

**Interfaces:**
- Consumes: executable `./script/test.sh` from the repository root.
- Produces: one public and two automated callers with no duplicated Swift orchestration.

- [ ] **Step 1: Replace public and workflow commands**

Use the following command in all three callers:

```bash
./script/test.sh
```

Keep the release-chain ScriptTests, shell syntax checks, packaging, and strict-concurrency build steps unchanged.

- [ ] **Step 2: Update the existing workflow policy fixture**

Change the required CI snippet from `swift test` to `./script/test.sh` so the supply-chain workflow contract recognizes the repository entrypoint.

- [ ] **Step 3: Run focused script contracts**

Run:

```bash
bash Tests/ScriptTests/test_entrypoint_tests.sh
bash Tests/ScriptTests/update_feed_tests.sh
```

Expected: both commands exit zero.

### Task 4: Verify the repository-level behavior

**Files:**
- Verify: `script/test.sh`
- Verify: `README.md`
- Verify: `.github/workflows/ci.yml`
- Verify: `.github/workflows/prepare-candidate.yml`

**Interfaces:**
- Consumes: the complete updated worktree.
- Produces: fresh test and static-analysis evidence for handoff.

- [ ] **Step 1: Run all ScriptTests**

```bash
bash Tests/ScriptTests/release_common_tests.sh
bash Tests/ScriptTests/package_verification_tests.sh
bash Tests/ScriptTests/update_feed_tests.sh
bash Tests/ScriptTests/test_entrypoint_tests.sh
```

- [ ] **Step 2: Run the complete Swift suite through the new entrypoint**

```bash
./script/test.sh
```

- [ ] **Step 3: Check syntax and orchestration drift**

```bash
find script Tests/ScriptTests -name '*.sh' -print0 | xargs -0 -n1 bash -n
rg -n 'swift test|--no-parallel|appkit_test_suites' README.md .github/workflows/ci.yml .github/workflows/prepare-candidate.yml
git diff --check
git status --short --branch
```

Expected: shell syntax and `git diff --check` succeed; the drift search returns no matches; Git reports only the intended uncommitted changes on detached `origin/main`.
