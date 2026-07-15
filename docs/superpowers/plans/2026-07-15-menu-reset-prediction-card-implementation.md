# Menu Reset Prediction Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the reset prediction the primary menu-bar visual, move the source link into that card, and leave only four application actions below the token metrics.

**Architecture:** Keep the feature inside `MenuBarView.swift`. Introduce private SwiftUI views for the prediction card, radar mark, status badge, and source chip; keep the public store and forecast models unchanged. `MenuActionID` becomes an application-action-only ordering contract.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, macOS 14+

## Global Constraints

- Preserve the 300pt menu-bar popover width.
- Use adaptive system colors and materials for Light and Dark Mode.
- Use red only when `forecast.isActive` is true.
- Keep English and Simplified Chinese localization.
- Preserve dashboard, refresh, settings, quit, and keyboard shortcut behavior.
- Do not modify forecast parsing, token aggregation, notification policy, or window structure.
- Keep all code, comments, identifiers, and commit messages in English.

---

### Task 1: Replace the menu action ordering contract

**Files:**
- Modify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift`

**Interfaces:**
- Produces: `MenuActionID.applicationActions: [MenuActionID]` containing dashboard, refresh, settings, and quit.
- Removes: `MenuActionID.source` and `MenuActionID.contextAction`.

- [ ] **Step 1: Write the failing action-order test**

```swift
@Test
func keepsOnlyApplicationActionsInTheMenuList() {
  #expect(MenuActionID.allCases == [.dashboard, .refresh, .settings, .quit])
  #expect(MenuActionID.applicationActions == MenuActionID.allCases)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter MenuActionLayoutTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: the test fails because `allCases` still begins with `.source`.

- [ ] **Step 3: Remove the source action from the enum and switch**

```swift
enum MenuActionID: String, CaseIterable, Hashable {
  case dashboard
  case refresh
  case settings
  case quit

  static let applicationActions = MenuActionID.allCases
}
```

Render only `MenuActionID.applicationActions` in the action list and retain the divider between token metrics and actions.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2.

Expected: `MenuActionLayoutTests` passes.

### Task 2: Build the time-first prediction card

**Files:**
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Produces: private `MenuResetPredictionCard`, `RadarLogo`, `ResetStatusBadge`, and `PredictionSourceChip` views.
- Consumes: `ResetForecast`, `Locale`, and `forecast.sourceURL`.

- [ ] **Step 1: Replace the compact header with `MenuResetPredictionCard`**

The card must render the localized title and status, show a large localized time when `predictedAt` exists, and show the existing no-active-window copy otherwise.

- [ ] **Step 2: Draw the radar mark from SwiftUI shapes**

Use concentric `Circle` strokes, a centered dot, and a rotated capsule scan line. Add a small red badge only when the forecast is active.

- [ ] **Step 3: Move the source interaction into the card**

Use a `Link(destination: forecast.sourceURL)` with the X symbol, localized source label, external-link glyph, full content shape, and pointer hover background.

- [ ] **Step 4: Add the localized card copy**

Add exact keys for `Next reset forecast`, `Monitoring`, `About %@`, and `Source: Tibo on X` in English and Simplified Chinese.

- [ ] **Step 5: Format and run focused tests**

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place Sources/CodexRadar/Views/MenuBarView.swift Tests/CodexRadarTests/MenuActionLayoutTests.swift
swift test --filter MenuActionLayoutTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: formatting succeeds and the focused test passes.

### Task 3: Verify the complete menu-bar app

**Files:**
- Verify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Verify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Verify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: the completed prediction card and application action list.
- Produces: a verified SwiftPM executable and review-ready branch diff.

- [ ] **Step 1: Run the complete SwiftPM test suite**

```bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all tests pass.

- [ ] **Step 2: Build the executable**

```bash
swift build
```

Expected: debug build succeeds without warnings or errors.

- [ ] **Step 3: Inspect the branch diff and run project-local autoreview**

```bash
git diff --check
.agents/skills/autoreview/scripts/autoreview --mode branch --base main
```

Expected: no whitespace errors and no accepted/actionable review findings.

