#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPKIT_TEST_SUITES='MenuActionLayoutTests|MenuBarControllerTests|MenuBarPanelActionsTests|SettingsWindowBridgeTests'

if (( $# != 0 )); then
  echo "usage: ./script/test.sh" >&2
  exit 64
fi

cd "$ROOT_DIR"

# Swift Testing 124.4 can crash when AppKit-facing and core suites share a process.
echo "Running AppKit-facing Swift test suites"
swift test --no-parallel --filter "$APPKIT_TEST_SUITES"

echo "Running remaining Swift test suites"
swift test --no-parallel --skip "$APPKIT_TEST_SUITES"
