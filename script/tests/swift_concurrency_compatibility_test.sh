#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOTIFICATION_SOURCE="$ROOT_DIR/Sources/CodexRadar/Services/ResetNotificationService.swift"
MENU_BAR_SOURCE="$ROOT_DIR/Sources/CodexRadar/Views/MenuBarView.swift"

grep -Fq '@preconcurrency import UserNotifications' "$NOTIFICATION_SOURCE" \
  || { echo "UserNotifications must use a preconcurrency import" >&2; exit 1; }

ruby -e '
  source = File.read(ARGV.fetch(0))
  expected = "  @MainActor\n  static let image: NSImage"
  abort "Menu bar image cache must be isolated to MainActor" unless source.include?(expected)
' "$MENU_BAR_SOURCE"

echo "swift_concurrency_compatibility_test: PASS"
