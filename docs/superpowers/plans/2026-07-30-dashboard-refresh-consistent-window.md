# Dashboard Refresh Consistent Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将刷新按钮从窗口 toolbar 移入仪表盘内容区，消除设置窗口在选项卡切换时的 `8pt` 内容跳动。

**Architecture:** `ContentView` 继续拥有刷新交互与 Store 依赖，但不再向 `Settings` scene 注入 toolbar。刷新入口成为页面内的首个右对齐控制行；`SettingsWindowTitleBridge` 恢复为只管理窗口标题，使所有选项卡下 `NSWindow.toolbar` 始终为 nil。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Testing、SwiftPM

## Global Constraints

- macOS 最低版本保持 14.0。
- 不新增依赖。
- 不修改 DashboardStore、ResetHistoryStore 或网络请求语义。
- 刷新按钮只在仪表盘显示。
- 保留 Command-R、刷新禁用状态与现有 loading overlay。
- 设置窗口默认尺寸保持 `1000 × 720pt`，最小尺寸保持 `980 × 620pt`。
- 所有代码、注释、标识符和提交信息使用 English。

---

## File Structure

- Modify: `Sources/CodexRadar/Views/ContentView.swift`
  - 负责仪表盘内容布局、页面内刷新按钮、Command-R 和刷新状态。
- Modify working tree: `Sources/CodexRadar/Views/SettingsView.swift`
  - 移除上一轮未提交的 toolbar 样式覆盖，使窗口桥接重新只负责标题。
- Verify: `Tests/CodexRadarTests/`
  - 运行完整现有测试套件；本次 scene/window 集成行为使用真实 AppKit 窗口验证。

### Task 1: Move Refresh Into Dashboard Content

**Files:**
- Modify: `Sources/CodexRadar/Views/ContentView.swift:8-40`
- Modify working tree: `Sources/CodexRadar/Views/SettingsView.swift:174-177`
- Test: `Tests/CodexRadarTests/`

**Interfaces:**
- Consumes: `DashboardStore.refresh() async`, `DashboardStore.isRefreshing`, `ResetHistoryStore.refresh(timeZone:)`, `EnvironmentValues.timeZone`
- Produces: `ContentView.refreshControl: some View`; a dashboard-only bordered button that preserves the existing refresh action and Command-R shortcut

- [ ] **Step 1: Record the failing runtime contract**

Build and launch the current debug bundle:

```bash
./script/build_and_run.sh --verify
```

Open the Settings window, select “Settings”, then inspect the Settings window:

```bash
app_pid="$(pgrep -x CodexRadar)"
lldb --batch -p "$app_pid" \
  -o 'expr -l objc++ -- @import AppKit' \
  -o 'expr -l objc++ -O -- (id)[[(NSApplication *)[NSApplication sharedApplication] windows] valueForKey:@"title"]' \
  -o 'expr -l objc++ -O -- (id)NSStringFromRect([(NSWindow *)[[(NSApplication *)[NSApplication sharedApplication] windows] objectAtIndex:2] contentLayoutRect])' \
  -o 'expr -l objc++ -O -- (id)[(NSWindow *)[[(NSApplication *)[NSApplication sharedApplication] windows] objectAtIndex:2] toolbar]' \
  -o 'detach'
```

Expected current Settings result:

```text
contentLayoutRect = {{0, 0}, {1000, 688}}
toolbar = nil
```

Select “Dashboard” and run the same command again.

Expected RED result:

```text
contentLayoutRect = {{0, 0}, {1000, 680}}
toolbar = <NSToolbar: ...>
```

This fails the desired invariant that every pane has `toolbar == nil` and a `688pt` content height.

- [ ] **Step 2: Replace the toolbar with a page-local control**

In `ContentView.body`, replace the top-level scroll content and remove the entire `.toolbar` modifier:

```swift
ScrollView {
  VStack(spacing: 0) {
    refreshControl

    VStack(spacing: 18) {
      ResetForecastCard(forecast: store.forecast)
      ResetHistoryView(store: historyStore, timeZone: timeZone)
      TokenUsageView(snapshot: store.tokenUsageSnapshot)

      if !store.issues.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(store.issues, id: \.self) { issue in
            Label(issue, systemImage: "exclamationmark.triangle")
          }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.top, 12)
  }
  .padding(24)
}
.frame(minWidth: 760, minHeight: 620)
```

Add this property inside `ContentView`, after `body`:

```swift
private var refreshControl: some View {
  HStack {
    Spacer()

    Button {
      historyStore.refresh(timeZone: timeZone)
      Task { await store.refresh() }
    } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("r", modifiers: .command)
    .disabled(store.isRefreshing)
  }
}
```

Do not change the overlay or lifecycle modifiers.

- [ ] **Step 3: Remove the obsolete AppKit toolbar override**

Restore `SettingsWindowTitleView.applyTitle()` to title-only ownership:

```swift
private func applyTitle() {
  window?.title = title
}
```

Do not add a SwiftUI `.windowToolbarStyle` scene modifier. The window must have no toolbar in every pane.

- [ ] **Step 4: Build and run the focused GREEN verification**

Build and launch the modified bundle:

```bash
./script/build_and_run.sh --verify
```

Use the same LLDB command from Step 1 after selecting “Settings”, “Dashboard”, “About”, and “Dashboard” again.

Expected result for every pane:

```text
contentLayoutRect = {{0, 0}, {1000, 688}}
toolbar = nil
```

Use Computer Use to confirm:

- the window frame stays `1000 × 720pt`;
- no titlebar or content jump occurs during pane changes;
- the dashboard shows a right-aligned bordered Refresh button above the first card;
- Settings and About do not show the button;
- the dashboard button remains exposed as an accessibility button named “Refresh”.

- [ ] **Step 5: Verify refresh behavior**

On Dashboard, click Refresh and inspect the accessibility tree.

Expected:

```text
Button "Refresh" becomes disabled while DashboardStore is refreshing.
No toolbar accessibility node appears.
```

After refresh completes, press Command-R.

Expected:

```text
The same button becomes disabled during refresh and returns to enabled afterward.
```

Confirm the existing error labels and loading overlay remain unchanged.

- [ ] **Step 6: Run the complete test suite**

Run:

```bash
swift test --no-parallel
```

Expected:

```text
Test run with 270 tests in 34 suites passed.
```

Run the final whitespace and scope checks:

```bash
git diff --check
git status --short
git diff --stat
```

Expected:

```text
No whitespace errors.
Only ContentView.swift has a production diff.
No unrelated files are modified or untracked.
```

- [ ] **Step 7: Commit the implementation**

```bash
git add Sources/CodexRadar/Views/ContentView.swift Sources/CodexRadar/Views/SettingsView.swift
git commit -m "fix: stabilize settings window tab transitions"
```

Expected:

```text
The commit contains the ContentView refresh-control migration.
SettingsView.swift is clean because the prior toolbarStyle line was never committed.
```
