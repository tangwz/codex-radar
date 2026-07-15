# Menu Actions Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inconsistent menu-bar buttons and link with one compact, aligned macOS action list in the user-approved order.

**Architecture:** Keep the change inside `MenuBarView.swift`. A small internal action identifier defines the stable order, while a private `MenuActionRow` owns the shared icon, label, trailing shortcut/progress indicator, hover background, and disabled appearance. Existing store, window, settings, URL, and termination actions remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, macOS 14+

## Global Constraints

- Preserve the exact order: prediction source, divider, dashboard, refresh, settings, quit.
- Show Command-D, Command-R, Command-, and Command-Q both visually and as real keyboard shortcuts.
- Use system semantic colors, SF Symbols, and adaptive hover styling for Light and Dark Mode.
- Keep English and Simplified Chinese localization.
- Do not modify Dashboard, reset forecasting, token scanning, notifications, or store behavior.
- Keep all code, comments, identifiers, and commit messages in English.

---

### Task 1: Define and test the stable action order

**Files:**
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Create: `Tests/CodexRadarTests/MenuActionLayoutTests.swift`

**Interfaces:**
- Produces: `MenuActionID`, an internal `String`, `CaseIterable`, and `Equatable` enum.
- Produces: `MenuActionID.applicationActions: [MenuActionID]` with dashboard, refresh, settings, and quit in order.
- Consumes: Existing `MenuBarView` action behavior.

- [ ] **Step 1: Write the failing layout test**

```swift
import Testing

@testable import CodexRadar

struct MenuActionLayoutTests {
  @Test
  func keepsPredictionSourceBeforeTheApplicationActionGroup() {
    #expect(MenuActionID.contextAction == .source)
    #expect(MenuActionID.applicationActions == [.dashboard, .refresh, .settings, .quit])
  }
}
```

- [ ] **Step 2: Run the focused test and verify the missing type failure**

Run:

```bash
swift test --filter MenuActionLayoutTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: compilation fails because `MenuActionID` does not exist.

- [ ] **Step 3: Add the minimal action identifier**

Add near the top of `MenuBarView.swift`:

```swift
enum MenuActionID: String, CaseIterable, Equatable {
  case source
  case dashboard
  case refresh
  case settings
  case quit

  static let contextAction = MenuActionID.source
  static let applicationActions: [MenuActionID] = [.dashboard, .refresh, .settings, .quit]
}
```

- [ ] **Step 4: Run the focused test and verify it passes**

Run the command from Step 2.

Expected: `MenuActionLayoutTests` passes.

- [ ] **Step 5: Commit the ordering contract**

```bash
git add Sources/CodexRadar/Views/MenuBarView.swift Tests/CodexRadarTests/MenuActionLayoutTests.swift
git commit -m "test: define menu action order"
```

### Task 2: Build the unified menu action rows

**Files:**
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `MenuActionID.contextAction` and `MenuActionID.applicationActions` from Task 1.
- Produces: `MenuActionRow`, a private SwiftUI view with `title`, `systemImage`, `shortcut`, `showsExternalLink`, and `isLoading` inputs.
- Preserves: Existing dashboard, refresh, settings, source URL, and quit behavior.

- [ ] **Step 1: Add the reusable row component**

Add to `MenuBarView.swift`:

```swift
private struct MenuActionRow: View {
  let title: LocalizedStringKey
  let systemImage: String
  var shortcut: String?
  var showsExternalLink = false
  var isLoading = false
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 18)

      Text(title)
        .lineLimit(1)

      Spacer(minLength: 12)

      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else if showsExternalLink {
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      } else if let shortcut {
        Text(shortcut)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .background(
      isHovered ? Color.primary.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
  }
}
```

- [ ] **Step 2: Replace the old buttons with the approved hierarchy**

Replace the existing action block with:

```swift
actionControl(MenuActionID.contextAction)
Divider()
ForEach(MenuActionID.applicationActions, id: \.self) { action in
  actionControl(action)
}
```

Add this helper inside `MenuBarView`:

```swift
@ViewBuilder
private func actionControl(_ action: MenuActionID) -> some View {
  switch action {
  case .source:
    Button {
      NSWorkspace.shared.open(store.forecast.sourceURL)
    } label: {
      MenuActionRow(
        title: "Open Prediction Source",
        systemImage: "link",
        showsExternalLink: true
      )
    }
    .buttonStyle(.plain)

  case .dashboard:
    Button {
      openWindow(id: "dashboard")
      NSApp.activate(ignoringOtherApps: true)
    } label: {
      MenuActionRow(
        title: "Open Dashboard",
        systemImage: "rectangle.grid.2x2",
        shortcut: "⌘D"
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut("d", modifiers: .command)

  case .refresh:
    Button {
      Task { await store.refresh() }
    } label: {
      MenuActionRow(
        title: "Check Now",
        systemImage: "arrow.clockwise",
        shortcut: "⌘R",
        isLoading: store.isRefreshing
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut("r", modifiers: .command)
    .disabled(store.isRefreshing)

  case .settings:
    SettingsLink {
      MenuActionRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,")
    }
    .buttonStyle(.plain)
    .keyboardShortcut(",", modifiers: .command)

  case .quit:
    Button {
      NSApplication.shared.terminate(nil)
    } label: {
      MenuActionRow(title: "Quit", systemImage: "power", shortcut: "⌘Q")
    }
    .buttonStyle(.plain)
    .keyboardShortcut("q", modifiers: .command)
  }
}
```

- [ ] **Step 3: Add the shortened quit localization**

Append to the English resource:

```text
"Quit" = "Quit";
```

Append to the Simplified Chinese resource:

```text
"Quit" = "退出";
```

- [ ] **Step 4: Format and build**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place --recursive Sources Tests
swift build
```

Expected: build succeeds without warnings or errors.

- [ ] **Step 5: Commit the visual implementation**

```bash
git add Sources/CodexRadar/Views/MenuBarView.swift Sources/CodexRadar/Resources
git commit -m "feat: redesign menu bar actions"
```

### Task 3: Verify behavior and rendered layout

**Files:**
- Verify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Verify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift`
- Verify: `dist/CodexRadar.app`

**Interfaces:**
- Consumes: Completed menu action layout and existing build script.
- Produces: A verified signed local application bundle with the redesigned action list.

- [ ] **Step 1: Run the complete test suite**

```bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all test suites pass.

- [ ] **Step 2: Rebuild, sign, and launch the app**

```bash
./script/build_and_run.sh --verify
codesign --verify --deep --strict --verbose=2 dist/CodexRadar.app
```

Expected: CodexRadar remains running and the app bundle satisfies its designated requirement.

- [ ] **Step 3: Inspect the menu in both languages**

Set `appLanguage` to `zh-Hans`, relaunch, open the menu, and verify the approved order and alignment. Repeat with `en`, then restore `system`.

Expected Chinese order:

```text
打开预测来源
────────
打开仪表盘   ⌘D
立即检查     ⌘R
设置…        ⌘,
退出         ⌘Q
```

- [ ] **Step 4: Verify pointer and action behavior**

Confirm the entire row highlights on hover and remains clickable. Confirm refresh shows a progress indicator and becomes disabled. Confirm source opens the current URL, dashboard opens the existing window, settings opens the Settings scene, and quit terminates the process.

- [ ] **Step 5: Commit any verification-only corrections**

If rendering verification requires corrections, commit only those reviewed changes:

```bash
git add Sources Tests
git commit -m "fix: polish menu action rendering"
```
