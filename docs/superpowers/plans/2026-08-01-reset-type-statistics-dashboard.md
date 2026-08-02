# Reset Type Statistics Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 CodexRadar 客户端严格解码 reset history v1.1 的 Hard / Banked / Both 计数，并在 Dashboard 默认展示 Both、支持本地切换类型、删除最近记录明细、通过柱状图 hover 显示次数。

**Architecture:** 协议模型将 `count` 保留为 Hard 兼容字段，并新增强校验的 `ResetCounts`。Presentation 按 view-local `ResetHistoryMetric` 投影周、月和月份计数；Store 和网络请求不感知类型选择。SwiftUI View 使用本地 segmented picker、Chart overlay 和系统自适应样式，Recent 数据继续解码以兼容后端，但不再渲染。

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Swift Testing, macOS 14+.

## Global Constraints

- 客户端在独立 worktree `codex/reset-type-statistics-dashboard` 中实现，不修改其他客户端任务 worktree。
- 只接受 history `schema_version = "1.1"`；缺少或非法 `counts` 时拒绝整份响应。
- 每个 bucket 必须满足 `count == counts.hard`、所有计数非负、`both <= hard`、`both <= banked`。
- 类型选择顺序固定为 Both、Hard、Banked，首次进入默认 Both。
- 类型选择仅属于当前 View 生命周期；切换类型不发起网络请求，刷新和时间范围变化保持当前选择。
- 类型选择同时驱动 This week、This month、月度柱状图及图表标题。
- Dashboard 不展示 Recent resets、Latest 5 或单条 reset 明细；协议仍解码 `recent` 以保持兼容校验。
- 柱顶不常驻次数；鼠标 hover 柱状图时显示月份和次数，零值月份也能命中并显示 `0`。
- All 范围继续水平滚动并默认定位最新月份，滚动后 hover 坐标仍正确。
- 保持系统自适应颜色、Light/Dark Mode、英文/简体中文和完整辅助功能描述。
- 不修改 ResetHistoryStore 的请求合并、刷新、范围扩展或时区调度语义。
- 不执行 push、发布、签名、notarization 或生产操作。
- 代码、注释、标识符、提交信息和代码块内容全部使用 English。

---

### Task 1: Decode and Validate Reset Counts

**Files:**
- Modify: `Sources/CodexRadar/Models/ResetHistory.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryTestSupport.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryDecodingTests.swift`

**Interfaces:**
- Produces: `ResetCounts`, `ResetHistoryInterval.counts`, `ResetMonthSummary.counts`
- Preserves: legacy `count`, `recent`, natural-boundary and ordering validation

- [ ] **Step 1: Update fixtures and write failing decoding tests**

Make the default fixture emit schema `1.1` and attach this shape to every current/month bucket:

```json
"counts":{"hard":7,"banked":3,"both":2}
```

Add tests proving a valid response decodes all three values and rejecting:

```text
missing counts
negative hard, banked or both
count different from counts.hard
both greater than hard
both greater than banked
schema_version other than 1.1
```

- [ ] **Step 2: Verify RED**

```bash
swift test --filter ResetHistoryDecodingTests
```

Expected: FAIL because the current model ignores `counts` and accepts schema `1.0`.

- [ ] **Step 3: Implement strict protocol types**

Add:

```swift
struct ResetCounts: Decodable, Equatable, Sendable {
  let hard: Int
  let banked: Int
  let both: Int

  func validate() throws {
    guard hard >= 0, banked >= 0, both >= 0,
      both <= hard, both <= banked
    else {
      throw ResetCountsValidationError.invalidCounts
    }
  }
}
```

Add `counts: ResetCounts` to `ResetHistoryInterval` and `ResetMonthSummary`. During `ResetHistory.init(from:)`, require `schemaVersion == "1.1"`; validate every bucket and require `count == counts.hard`. Convert validation failures to the existing keyed `DecodingError.dataCorruptedError` style rather than leaking an internal error.

- [ ] **Step 4: Verify GREEN and commit**

```bash
swift test --filter ResetHistoryDecodingTests
git add Sources/CodexRadar/Models/ResetHistory.swift Tests/CodexRadarTests/ResetHistoryTestSupport.swift Tests/CodexRadarTests/ResetHistoryDecodingTests.swift
git commit -m "feat: decode reset type counts"
```

Expected: decoding tests PASS.

### Task 2: Project the Selected Reset Metric

**Files:**
- Modify: `Sources/CodexRadar/Models/ResetHistoryPresentation.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1 `ResetCounts`
- Produces: `ResetHistoryMetric` and metric-specific presentation counts
- Preserves: range cropping, month identities, labels and range description

- [ ] **Step 1: Write failing metric projection tests**

Add table-driven coverage for:

```swift
enum ResetHistoryMetric: String, CaseIterable, Identifiable {
  case both
  case hard
  case banked

  var id: Self { self }
}
```

For each metric, assert `weekCount`, `monthCount` and every `Month.count` come from the matching `ResetCounts` field. Remove assertions and presentation state related to recent rows.

- [ ] **Step 2: Verify RED**

```bash
swift test --filter ResetHistoryPresentationTests
```

Expected: FAIL because presentation has no metric input and always uses legacy `count`.

- [ ] **Step 3: Implement metric projection**

Add:

```swift
extension ResetCounts {
  func count(for metric: ResetHistoryMetric) -> Int {
    switch metric {
    case .both: both
    case .hard: hard
    case .banked: banked
    }
  }
}
```

Change the presentation initializer to:

```swift
init(
  history: ResetHistory,
  selectedRange: ResetHistoryRange,
  metric: ResetHistoryMetric,
  locale: Locale
)
```

Store `metric`, derive week/month/monthly counts with `count(for:)`, and remove `Recent` plus `recent` from presentation. Do not remove `ResetHistory.recent` from the protocol model.

- [ ] **Step 4: Verify GREEN and commit**

```bash
swift test --filter ResetHistoryPresentationTests
git add Sources/CodexRadar/Models/ResetHistoryPresentation.swift Tests/CodexRadarTests/ResetHistoryPresentationTests.swift
git commit -m "feat: project reset history metrics"
```

Expected: presentation tests PASS.

### Task 3: Add the Metric Picker and Hover Tooltip

**Files:**
- Modify: `Sources/CodexRadar/Views/ResetHistoryView.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryPresentationTests.swift`

**Interfaces:**
- Consumes: Task 2 `ResetHistoryMetric` and metric-specific presentation
- Produces: view-local metric selection and pointer tooltip
- Preserves: range picker, All scrolling, loading/unavailable states and issue display

- [ ] **Step 1: Write failing structural UI tests**

Extend the existing source-structure test to require:

```text
@State private var selectedMetric: ResetHistoryMetric = .both
Picker("Reset type", selection: $selectedMetric)
.chartOverlay
.onContinuousHover
```

Also assert the source no longer contains `recentList(`, `Text("Recent resets")`, `Text("Latest 5")` or a BarMark `.annotation(position: .top)` that always displays the count.

- [ ] **Step 2: Verify RED**

```bash
swift test --filter ResetHistoryPresentationTests
```

Expected: FAIL because the existing view has no metric picker or hover overlay and still renders recent rows/count annotations.

- [ ] **Step 3: Implement view-local metric selection**

Add `selectedMetric` state defaulting to `.both`. Put a segmented picker in the card header with tags ordered `.both`, `.hard`, `.banked`. Pass `selectedMetric` into `ResetHistoryPresentation`; do not call the Store from the picker setter.

Use metric-specific localized chart titles:

```text
Hard + banked resets by month
Hard resets by month
Banked resets by month
```

Delete `recentList` and its call site. Keep `historyIssue` directly below the chart.

- [ ] **Step 4: Implement categorical hover without permanent labels**

Use stable month IDs for the Chart x-values and render labels through `AxisMarks`. Add a clear `chartOverlay` with `onContinuousHover`; translate the pointer into the plot-frame coordinate and use `ChartProxy.value(atX:)` to resolve the nearest month ID. Clear hover state when the pointer exits.

Render the hovered value through a transparent `RuleMark` annotation so a zero-count month still has a tooltip. The tooltip contains the displayed month label and formatted count. Keep the overlay inside each Chart instance so horizontally scrolled All content uses local coordinates.

Add per-month accessibility labels containing metric, month and count. Do not rely on pointer hover for accessibility.

- [ ] **Step 5: Verify GREEN and commit**

```bash
swift test --filter ResetHistoryPresentationTests
swift test --filter ResetHistoryStoreTests
git add Sources/CodexRadar/Views/ResetHistoryView.swift Tests/CodexRadarTests/ResetHistoryPresentationTests.swift
git commit -m "feat: add reset metric chart controls"
```

Expected: UI structure, presentation and Store tests PASS.

### Task 4: Localize and Verify the Client

**Files:**
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/CodexRadarTests/AppLocalizationTests.swift`
- Verify: all client files

**Interfaces:**
- Consumes: Task 3 UI strings
- Produces: complete English and Simplified Chinese copy

- [ ] **Step 1: Write failing localization tests**

Require both languages for:

```text
Reset type
Both
Hard
Banked
Hard + banked resets by month
Hard resets by month
Banked resets by month
%@, %lld resets
```

Remove Recent resets and Latest 5 from the reset-statistics localization expectation list.

- [ ] **Step 2: Verify RED, add translations and verify GREEN**

```bash
swift test --filter AppLocalizationTests
```

Add English values identical to their keys. Use `二者同时` for Both and concise Simplified Chinese chart titles/tooltip copy. Re-run the same command; expected PASS.

- [ ] **Step 3: Run complete client verification**

```bash
swift test
git diff --check
git status --short
```

Expected: all Swift tests PASS and `git diff --check` emits no output.

- [ ] **Step 4: Commit and stop at delivery**

```bash
git add Sources/CodexRadar/Resources/en.lproj/Localizable.strings Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings Tests/CodexRadarTests/AppLocalizationTests.swift
git commit -m "feat: localize reset metric statistics"
```

Report final HEAD, commits and tests. Do not push, release, sign or notarize without a separate explicit request.
