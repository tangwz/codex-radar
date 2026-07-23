# Dashboard History Range Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 macOS Dashboard 的重置统计迁移到新版 `/v1/history` range 协议，默认展示近 6 个自然月，并支持 `3M / 6M / 12M / All` 切换、按需请求、自然周/月边界刷新和全量图表横向滚动。

**Architecture:** `ResetHistory` 负责严格验证服务端权威快照；`ResetHistoryService` 只处理协议与请求；`ResetHistoryStore` 作为 Dashboard 会话内的协调器，区分用户选择范围与已加载数据范围，优先本地裁剪并在数据不足时请求扩展范围。SwiftUI presentation 只消费已验证快照并生成可见月份，视图不缓存、不推算计数，也不改变现有全宽 Dashboard 布局。

**Tech Stack:** Swift 6、SwiftUI、Charts、Observation through Combine、Foundation `Calendar`/`TimeZone`、Swift Testing、macOS 14+

## Global Constraints

- 后端 `GET /v1/history` 必须先部署；客户端不兼容旧的 `year` / `available_years` 响应。
- 请求始终发送 `time_zone`；默认 `6m` 省略 `range`，`12m` 和 `all` 明确发送，`3m` 复用 `6m` 数据。
- Dashboard 首次打开才发 history 请求；关闭后不刷新、不继续等待自然边界。
- `3M / 6M` 在已有 `6m` 或更大快照覆盖时仅本地切换；首次进入 `12M / All` 时请求对应范围。
- 当前周、当前月、最近五条在切换范围时不裁剪、不单独请求，始终来自同一服务端响应。
- 请求失败时保留最后一次成功结果和已提交选择，仅展示非阻塞错误。
- 成功响应后，Dashboard 保持打开时在下一个自然周或自然月边界（取较早者）重新请求。
- `All` 使用固定最小柱宽与横向滚动，进入后默认定位到最新月份；固定范围不横向滚动。
- 不增加磁盘缓存、历史游标分页、客户端统计回填或后台轮询。
- `TokenUsageView` 保持全宽和现有结构；不增加侧栏，不压缩卡片。
- 所有 Swift 标识符、代码注释、提交信息和 Markdown 代码块内容使用 English。

## File Structure

- `Sources/CodexRadar/Models/ResetHistoryRange.swift`：范围值、覆盖关系、请求归一化。
- `Sources/CodexRadar/Models/ResetHistory.swift`：新版响应解码及动态自然月校验。
- `Sources/CodexRadar/Models/ResetHistoryRefreshSchedule.swift`：计算下一自然周/月刷新边界。
- `Sources/CodexRadar/Services/ResetHistoryService.swift`：新版 query 参数与响应匹配。
- `Sources/CodexRadar/Stores/ResetHistoryStore.swift`：Dashboard 生命周期、范围协调、竞态和边界 timer。
- `Sources/CodexRadar/Models/ResetHistoryPresentation.swift`：范围裁剪、月份标签与日期范围。
- `Sources/CodexRadar/Views/ResetHistoryView.swift`：range segmented control、图表状态和 `All` 滚动。
- `Sources/CodexRadar/Resources/*/Localizable.strings`：新增可见文案。
- `Tests/CodexRadarTests/ResetHistoryTestSupport.swift`：动态月份 fixture。
- `Tests/CodexRadarTests/ResetHistoryDecodingTests.swift`：协议与不变量测试。
- `Tests/CodexRadarTests/ResetHistoryServiceTests.swift`：请求参数和响应匹配测试。
- `Tests/CodexRadarTests/ResetHistoryRefreshScheduleTests.swift`：自然边界和 DST 测试。
- `Tests/CodexRadarTests/ResetHistoryStoreTests.swift`：按需加载、失败保留、竞态和生命周期测试。
- `Tests/CodexRadarTests/ResetHistoryPresentationTests.swift`：可见范围与格式测试。
- `Tests/CodexRadarTests/AppLocalizationTests.swift`：中英文资源完整性测试。

---

### Task 1: Adopt the Dynamic Range Response Model

**Files:**
- Create: `Sources/CodexRadar/Models/ResetHistoryRange.swift`
- Modify: `Sources/CodexRadar/Models/ResetHistory.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryTestSupport.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryDecodingTests.swift`

**Interfaces:**
- Produces: `ResetHistoryRange = threeMonths | sixMonths | twelveMonths | all`.
- Produces: `ResetHistory.range`.
- Removes: `ResetHistory.year` and `ResetHistory.availableYears`.
- Preserves: strict validation of current week/month, recent ordering, unique IDs, and non-negative counts.

- [ ] **Step 1: Replace year fixtures with rolling month fixtures**

In `Tests/CodexRadarTests/ResetHistoryTestSupport.swift`, retain the current interval helper and replace the January-based summary builder with a builder that starts at an explicit local natural month:

```swift
func resetHistoryMonthSummariesJSON(
  startYear: Int,
  startMonth: Int,
  count: Int,
  timeZoneIdentifier: String
) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
  let start = calendar.date(
    from: DateComponents(year: startYear, month: startMonth, day: 1)
  )!

  return (0..<count).map { offset in
    let date = calendar.date(byAdding: .month, value: offset, to: start)!
    return resetHistoryMonthSummaryJSON(
      year: calendar.component(.year, from: date),
      month: calendar.component(.month, from: date),
      timeZoneIdentifier: timeZoneIdentifier
    )
  }.joined(separator: ",")
}
```

Add one complete response helper:

```swift
func resetHistoryJSON(
  range: String = "6m",
  startYear: Int = 2026,
  startMonth: Int = 2,
  monthCount: Int = 6,
  timeZoneIdentifier: String = "Asia/Shanghai",
  generatedAt: String = "2026-07-19T09:00:00Z",
  recent: String = ""
) -> String
```

The helper must derive `current.week`, `current.month`, and all bucket boundaries from `generatedAt` and `timeZoneIdentifier`; do not copy UTC boundaries into individual tests.

- [ ] **Step 2: Rewrite decoding tests for the new contract**

Replace assertions for `year` and `availableYears` with:

```swift
let history = try decodeHistory(resetHistoryJSON())

#expect(history.schemaVersion == "1.0")
#expect(history.range == .sixMonths)
#expect(history.months.map(\.month) == [
  "2026-02", "2026-03", "2026-04",
  "2026-05", "2026-06", "2026-07",
])
#expect(history.current.month.count == history.months.last?.count)
```

Add table-driven failures for:

- unknown or missing `range`;
- `3m`, `6m`, or `12m` with the wrong number of buckets;
- empty `all`;
- duplicate, skipped, reversed, or malformed `YYYY-MM` identifiers;
- a bucket whose `from`/`to` is not its natural local month;
- a final bucket that is not the current month for `generated_at`;
- a `current.month` that differs from the final bucket;
- more than five recent rows, duplicate IDs, or unstable descending order.

- [ ] **Step 3: Run the focused tests and verify RED**

```bash
swift test --filter ResetHistoryDecodingTests
```

Expected: FAIL because the model still requires `year` and exactly twelve January-to-December buckets.

- [ ] **Step 4: Add the range type**

Create `Sources/CodexRadar/Models/ResetHistoryRange.swift`:

```swift
import Foundation

enum ResetHistoryRange: String, CaseIterable, Decodable, Equatable, Identifiable, Sendable {
  case threeMonths = "3m"
  case sixMonths = "6m"
  case twelveMonths = "12m"
  case all

  var id: String { rawValue }

  var fixedMonthCount: Int? {
    switch self {
    case .threeMonths: 3
    case .sixMonths: 6
    case .twelveMonths: 12
    case .all: nil
    }
  }

  var requestedRange: ResetHistoryRange {
    self == .threeMonths ? .sixMonths : self
  }

  var queryValue: String? {
    self == .sixMonths ? nil : rawValue
  }

  func covers(_ range: ResetHistoryRange) -> Bool {
    if self == .all { return true }
    guard let available = fixedMonthCount, let required = range.fixedMonthCount else {
      return self == range
    }
    return available >= required
  }
}
```

- [ ] **Step 5: Decode and validate dynamic month buckets**

In `ResetHistory.swift`:

- replace `year` and `availableYears` with `let range: ResetHistoryRange`;
- replace their coding keys with `.range`;
- require at least one month;
- require exact fixed-range counts and allow any positive `all` count;
- parse each identifier with a strict `yyyy-MM` parser using the POSIX locale;
- verify each bucket is one natural month in `history.timeZone`;
- verify buckets are contiguous and strictly ascending;
- verify the final bucket matches the natural month containing `generatedAt`;
- verify `current.month` equals the final bucket's `from`, `to`, and `count`;
- keep all existing current-week and recent-list validation.

Use a parser that rejects lenient input:

```swift
private func monthComponents(from identifier: String) -> DateComponents? {
  guard identifier.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
  else { return nil }
  let parts = identifier.split(separator: "-")
  guard
    parts.count == 2,
    let year = Int(parts[0]),
    let month = Int(parts[1])
  else { return nil }
  return DateComponents(year: year, month: month, day: 1)
}
```

- [ ] **Step 6: Format, verify GREEN, and commit**

```bash
swift format --in-place \
  Sources/CodexRadar/Models/ResetHistoryRange.swift \
  Sources/CodexRadar/Models/ResetHistory.swift \
  Tests/CodexRadarTests/ResetHistoryTestSupport.swift \
  Tests/CodexRadarTests/ResetHistoryDecodingTests.swift
swift test --filter ResetHistoryDecodingTests
git add Sources/CodexRadar/Models/ResetHistoryRange.swift \
  Sources/CodexRadar/Models/ResetHistory.swift \
  Tests/CodexRadarTests/ResetHistoryTestSupport.swift \
  Tests/CodexRadarTests/ResetHistoryDecodingTests.swift
git commit -m "feat: decode reset history ranges"
```

Expected: range and decoding tests pass.

---

### Task 2: Send the Normalized History Request

**Files:**
- Modify: `Sources/CodexRadar/Services/ResetHistoryService.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryServiceTests.swift`

**Interfaces:**
- Changes: `fetch(timeZoneIdentifier:range:) async throws -> ResetHistory`.
- Sends no `range` query item for `.sixMonths`.
- Rejects a successful response whose `time_zone` or normalized `range` differs from the request.

- [ ] **Step 1: Write failing request-shape tests**

Add:

```swift
@Test(arguments: [
  (ResetHistoryRange.sixMonths, nil),
  (.twelveMonths, "12m"),
  (.all, "all"),
])
func sendsNormalizedRange(
  _ range: ResetHistoryRange,
  _ expectedQueryValue: String?
) async throws {
  let recorder = HistoryRequestRecorder()
  let service = ResetHistoryService(
    loader: HTTPDataLoader { request in
      await recorder.record(request)
      return (
        Data(resetHistoryJSON(range: range.rawValue).utf8),
        historyResponse(status: 200, url: request.url!)
      )
    }
  )

  _ = try await service.fetch(
    timeZoneIdentifier: "Asia/Shanghai",
    range: range
  )
  let request = try #require(await recorder.request)
  let components = try #require(
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
  )
  #expect(components.queryItems?.first { $0.name == "range" }?.value == expectedQueryValue)
}
```

Keep assertions for path, `time_zone`, timeout and `.reloadIgnoringLocalCacheData`. Add a mismatched response-range test and retain all HTTP error mapping tests.

- [ ] **Step 2: Run the service tests and verify RED**

```bash
swift test --filter ResetHistoryServiceTests
```

Expected: FAIL because the service still accepts `year` and sends the obsolete query item.

- [ ] **Step 3: Change the service signature and response guard**

Use:

```swift
func fetch(
  timeZoneIdentifier: String,
  range: ResetHistoryRange
) async throws -> ResetHistory {
  guard
    TimeZone(identifier: timeZoneIdentifier) != nil,
    var components = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)
  else {
    throw ResetHistoryServiceError.invalidRequest
  }

  components.queryItems = [
    URLQueryItem(name: "time_zone", value: timeZoneIdentifier)
  ]
  if let queryValue = range.queryValue {
    components.queryItems?.append(
      URLQueryItem(name: "range", value: queryValue)
    )
  }
```

After decoding:

```swift
guard
  history.timeZone == timeZoneIdentifier,
  history.range == range
else {
  throw ResetHistoryServiceError.invalidResponse
}
```

The store must pass `selectedRange.requestedRange`, so this method never receives `.threeMonths` in production. Keep the method total for tests; if called with `.threeMonths`, it sends `range=3m`.

- [ ] **Step 4: Format, verify GREEN, and commit**

```bash
swift format --in-place Sources/CodexRadar/Services/ResetHistoryService.swift \
  Tests/CodexRadarTests/ResetHistoryServiceTests.swift
swift test --filter ResetHistoryServiceTests
git add Sources/CodexRadar/Services/ResetHistoryService.swift \
  Tests/CodexRadarTests/ResetHistoryServiceTests.swift
git commit -m "feat: request reset history ranges"
```

Expected: service tests pass and no request contains `year`.

---

### Task 3: Coordinate Local Range Switching and Natural Boundary Refresh

**Files:**
- Create: `Sources/CodexRadar/Models/ResetHistoryRefreshSchedule.swift`
- Create: `Tests/CodexRadarTests/ResetHistoryRefreshScheduleTests.swift`
- Modify: `Sources/CodexRadar/Stores/ResetHistoryStore.swift`
- Modify: `Tests/CodexRadarTests/ResetHistoryStoreTests.swift`

**Interfaces:**
- Changes: `FetchHistory = @Sendable (String, ResetHistoryRange) async throws -> ResetHistory`.
- Adds published `selectedRange`, `pendingRange`.
- Adds injectable `waitUntil` seam for deterministic boundary tests.
- Preserves active-query generation guards and one trailing reload for reset changes.

- [ ] **Step 1: Write pure schedule tests**

Create `Tests/CodexRadarTests/ResetHistoryRefreshScheduleTests.swift` with:

- a Wednesday response refreshes at the following ISO Monday before month end;
- a response near month end refreshes at the next local month boundary before week end;
- Asia/Shanghai and America/Los_Angeles produce correct absolute dates;
- a DST transition still targets local midnight;
- the returned date is strictly later than `generatedAt`.

Example:

```swift
@Test
func choosesTheEarlierMonthBoundary() throws {
  let generatedAt = try #require(
    ISO8601DateFormatter().date(from: "2026-07-31T20:00:00Z")
  )
  let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))

  #expect(
    ResetHistoryRefreshSchedule.nextBoundary(
      after: generatedAt,
      timeZone: zone
    ) == ISO8601DateFormatter().date(from: "2026-07-31T16:00:01Z")
  )
}
```

- [ ] **Step 2: Write store tests before changing the store**

Replace year-selection tests with these cases:

- first Dashboard appearance requests `.sixMonths`;
- selecting `.threeMonths` from a `.sixMonths` snapshot makes no request;
- selecting `.sixMonths` again makes no request;
- first `.twelveMonths` selection requests `.twelveMonths`;
- first `.all` selection requests `.all`;
- a committed `.all` snapshot serves every later selection locally;
- a failed expansion keeps the old snapshot and old selected range;
- selecting a new expansion cancels/invalidates an older response;
- refresh, time-zone change and last-reset trailing reload request the current selected range's normalized fetch range;
- disappearance cancels load and boundary wait without discarding the last successful snapshot;
- a successful response schedules one boundary wait;
- firing the boundary wait while active triggers one reload;
- a newer successful response replaces the previous boundary wait;
- the boundary does not reload after disappearance.

The controlled fetch request becomes:

```swift
struct HistoryRequest: Equatable, Sendable {
  let timeZoneIdentifier: String
  let range: ResetHistoryRange
}
```

Add a controlled waiter that records dates and resumes explicitly:

```swift
actor ControlledHistoryWaiter {
  private var continuations: [CheckedContinuation<Void, Error>] = []
  private(set) var dates: [Date] = []

  func wait(until date: Date) async throws {
    dates.append(date)
    try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func fireNext() {
    continuations.removeFirst().resume()
  }
}
```

- [ ] **Step 3: Run schedule and store tests and verify RED**

```bash
swift test --filter ResetHistoryRefreshScheduleTests
swift test --filter ResetHistoryStoreTests
```

Expected: FAIL because there is no boundary scheduler and the store still coordinates years.

- [ ] **Step 4: Implement the pure refresh schedule**

Create `Sources/CodexRadar/Models/ResetHistoryRefreshSchedule.swift`:

```swift
import Foundation

enum ResetHistoryRefreshSchedule {
  static func nextBoundary(
    after generatedAt: Date,
    timeZone: TimeZone
  ) -> Date? {
    var weekCalendar = Calendar(identifier: .iso8601)
    weekCalendar.timeZone = timeZone
    var monthCalendar = Calendar(identifier: .gregorian)
    monthCalendar.timeZone = timeZone

    guard
      let week = weekCalendar.dateInterval(of: .weekOfYear, for: generatedAt),
      let month = monthCalendar.dateInterval(of: .month, for: generatedAt)
    else {
      return nil
    }
    return min(week.end, month.end).addingTimeInterval(1)
  }
}
```

The one-second offset avoids an edge request being evaluated in the previous interval because of clock or serialization precision.

- [ ] **Step 5: Replace year state with range state**

In `ResetHistoryStore`:

```swift
typealias FetchHistory =
  @Sendable (String, ResetHistoryRange) async throws -> ResetHistory
typealias WaitUntil = @Sendable (Date) async throws -> Void

@Published private(set) var selectedRange: ResetHistoryRange = .sixMonths
@Published private(set) var pendingRange: ResetHistoryRange?

private struct Query: Equatable, Sendable {
  let timeZoneIdentifier: String
  let fetchRange: ResetHistoryRange
  let targetRange: ResetHistoryRange
}
```

The live waiter must use cancellation-aware sleep:

```swift
waitUntil: @escaping WaitUntil = { date in
  let duration = max(0, date.timeIntervalSinceNow)
  try await Task.sleep(for: .seconds(duration))
}
```

Implement selection with one local-coverage path and one request path:

```swift
func selectRange(_ range: ResetHistoryRange, timeZone: TimeZone) {
  guard isDashboardActive else { return }
  if history?.range.covers(range) == true {
    cancelExpansionRequestIfNeeded()
    selectedRange = range
    pendingRange = nil
    return
  }
  request(
    Query(
      timeZoneIdentifier: timeZone.identifier,
      fetchRange: range.requestedRange,
      targetRange: range
    ),
    trigger: .ordinary
  )
}
```

Implement these invariants explicitly:

- `dashboardDidAppear` requests the current `selectedRange.requestedRange`;
- ordinary refresh uses `selectedRange.requestedRange`; replacing a larger snapshot with that fresh response is allowed because only the last successful response is retained;
- while an expansion is loading, `pendingRange` is the requested target and the committed chart remains visible;
- only a matching generation may commit;
- success assigns `history`, then `selectedRange = query.targetRange`;
- failure leaves `history` and `selectedRange` untouched;
- a reset change during any active request schedules exactly one trailing request for the same target;
- cancellation and disappearance clear transient state, not committed state.

`cancelExpansionRequestIfNeeded()` must increment `generation`, cancel and clear `loadTask`, clear `activeQuery`, `pendingRange`, and `isLoading`, and leave `history`, `selectedRange`, `issue`, and `boundaryTask` unchanged.

- [ ] **Step 6: Schedule and cancel boundary refreshes**

Add `boundaryTask` and schedule only after a successful commit:

```swift
private var boundaryTask: Task<Void, Never>?

private func scheduleBoundaryRefresh(after history: ResetHistory) {
  boundaryTask?.cancel()
  guard
    isDashboardActive,
    let timeZone = TimeZone(identifier: history.timeZone),
    let boundary = ResetHistoryRefreshSchedule.nextBoundary(
      after: history.generatedAt,
      timeZone: timeZone
    )
  else { return }
  let waitUntil = waitUntil
  boundaryTask = Task { [weak self] in
    do {
      try await waitUntil(boundary)
      guard !Task.isCancelled, let self else { return }
      await self.refreshAtBoundary(timeZone: timeZone)
    } catch is CancellationError {
      return
    } catch {
      return
    }
  }
}
```

Keep all state mutation on `@MainActor`. Cancel `boundaryTask` on Dashboard disappearance, time-zone changes, and before replacing it after a successful response.

- [ ] **Step 7: Format, verify GREEN, and commit**

```bash
swift format --in-place \
  Sources/CodexRadar/Models/ResetHistoryRefreshSchedule.swift \
  Sources/CodexRadar/Stores/ResetHistoryStore.swift \
  Tests/CodexRadarTests/ResetHistoryRefreshScheduleTests.swift \
  Tests/CodexRadarTests/ResetHistoryStoreTests.swift
swift test --filter ResetHistoryRefreshScheduleTests
swift test --filter ResetHistoryStoreTests
git add Sources/CodexRadar/Models/ResetHistoryRefreshSchedule.swift \
  Sources/CodexRadar/Stores/ResetHistoryStore.swift \
  Tests/CodexRadarTests/ResetHistoryRefreshScheduleTests.swift \
  Tests/CodexRadarTests/ResetHistoryStoreTests.swift
git commit -m "feat: coordinate dashboard history ranges"
```

Expected: all store and scheduling tests pass without wall-clock sleeps.

---

### Task 4: Present and Render the Range Controls

**Files:**
- Modify: `Sources/CodexRadar/Models/ResetHistoryPresentation.swift`
- Modify: `Sources/CodexRadar/Views/ResetHistoryView.swift`
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/CodexRadarTests/ResetHistoryPresentationTests.swift`
- Modify: `Tests/CodexRadarTests/AppLocalizationTests.swift`

**Interfaces:**
- Changes: `ResetHistoryPresentation(history:selectedRange:locale:)`.
- Produces: visible month suffix, range description, fixed/all month labels.
- Preserves: week/month tiles, recent five rows, retry, and non-blocking issue display.

- [ ] **Step 1: Write failing presentation tests**

Cover:

```swift
let sixMonthHistory = try decodeHistory(resetHistoryJSON())

#expect(
  ResetHistoryPresentation(
    history: sixMonthHistory,
    selectedRange: .threeMonths,
    locale: Locale(identifier: "en_US")
  ).months.map(\.id) == ["2026-05", "2026-06", "2026-07"]
)
#expect(
  ResetHistoryPresentation(
    history: sixMonthHistory,
    selectedRange: .sixMonths,
    locale: Locale(identifier: "en_US")
  ).rangeDescription == "Feb 2026 – Jul 2026"
)
```

Also test:

- `.twelveMonths` keeps twelve buckets across a year boundary;
- `.all` keeps every bucket;
- fixed-range labels use abbreviated month names;
- `all` labels include a short year to disambiguate repeated months;
- response time zone, not current system time zone, formats recent rows and labels.

- [ ] **Step 2: Run presentation tests and verify RED**

```bash
swift test --filter ResetHistoryPresentationTests
```

Expected: FAIL because presentation still exposes years and cannot crop ranges.

- [ ] **Step 3: Implement visible-month presentation**

Change the initializer:

```swift
init(
  history: ResetHistory,
  selectedRange: ResetHistoryRange,
  locale: Locale
) {
  let timeZone = TimeZone(identifier: history.timeZone)!
  let visibleSummaries: ArraySlice<ResetMonthSummary>
  if let count = selectedRange.fixedMonthCount {
    visibleSummaries = history.months.suffix(count)
  } else {
    visibleSummaries = history.months[...]
  }

  let monthStyle =
    selectedRange == .all
      ? Date.FormatStyle(
          date: .omitted,
          time: .omitted,
          locale: locale,
          timeZone: timeZone
        ).month(.abbreviated).year(.twoDigits)
      : Date.FormatStyle(
          date: .omitted,
          time: .omitted,
          locale: locale,
          timeZone: timeZone
        ).month(.abbreviated)
```

Add:

```swift
let selectedRange: ResetHistoryRange
let rangeDescription: String
```

Format `rangeDescription` from the first visible bucket's `from` through the final bucket's `from`, including years at both ends. Keep recent and counts unchanged.

- [ ] **Step 4: Replace the year picker with the range control**

In `ResetHistoryView`:

- keep `Reset statistics` as the card header;
- move a compact loading indicator beside the header while a range expansion is pending;
- label the chart section `Resets by month`;
- place a segmented `3M / 6M / 12M / All` picker at the chart header's trailing edge;
- add an Info control whose help/popover explains that months use natural-month boundaries in the selected IANA time zone;
- bind picker selection to `store.pendingRange ?? store.selectedRange`;
- call `store.selectRange(_:timeZone:)`;
- keep the old chart visible with reduced opacity while an expansion request runs;
- show `rangeDescription` as secondary text;
- do not change the two current-count tiles or recent-five list.

Use stable picker labels:

```swift
private func rangeLabel(_ range: ResetHistoryRange) -> LocalizedStringKey {
  switch range {
  case .threeMonths: "3M"
  case .sixMonths: "6M"
  case .twelveMonths: "12M"
  case .all: "All"
  }
}
```

Add an explicit, keyboard-accessible Info popover:

```swift
@State private var isShowingMonthInfo = false

Button {
  isShowingMonthInfo.toggle()
} label: {
  Image(systemName: "info.circle")
}
.buttonStyle(.plain)
.accessibilityLabel(Text("About monthly reset statistics"))
.popover(isPresented: $isShowingMonthInfo) {
  Text("Months follow natural boundaries in your selected time zone.")
    .padding()
    .frame(width: 280)
}
```

- [ ] **Step 5: Add the `All` horizontal chart**

Extract a shared chart builder so fixed and all modes render identical bars. For `.all`, wrap it in `ScrollViewReader` and `ScrollView(.horizontal)`:

```swift
GeometryReader { proxy in
  ScrollViewReader { scrollProxy in
    ScrollView(.horizontal) {
      monthlyBars(presentation.months)
        .frame(
          width: max(
            proxy.size.width,
            CGFloat(presentation.months.count) * 56
          ),
          height: 220
        )
        .id(presentation.months.last?.id)
    }
    .onAppear {
      scrollProxy.scrollTo(
        presentation.months.last?.id,
        anchor: .trailing
      )
    }
  }
}
.frame(height: 220)
```

Give the complete all-mode chart the latest month ID so `scrollTo` can align its trailing edge. Re-run the scroll when a newly committed `.all` snapshot changes that ID. Fixed `3M / 6M / 12M` uses the normal full-width chart without horizontal scrolling.

- [ ] **Step 6: Update localization**

Add to both resource files:

```text
"Resets by month"
"Time range"
"All"
"About monthly reset statistics"
"Months follow natural boundaries in your selected time zone."
```

Use these Simplified Chinese translations:

```text
"按月重置次数"
"时间范围"
"全部"
"关于每月重置统计"
"月份按所选时区的自然月边界统计。"
```

Keep `Year` because `TokenUsageView` still uses it. Update `AppLocalizationTests` to assert the new strings.

- [ ] **Step 7: Format, verify GREEN, and commit**

```bash
swift format --in-place \
  Sources/CodexRadar/Models/ResetHistoryPresentation.swift \
  Sources/CodexRadar/Views/ResetHistoryView.swift \
  Tests/CodexRadarTests/ResetHistoryPresentationTests.swift \
  Tests/CodexRadarTests/AppLocalizationTests.swift
swift test --filter ResetHistoryPresentationTests
swift test --filter AppLocalizationTests
git add Sources/CodexRadar/Models/ResetHistoryPresentation.swift \
  Sources/CodexRadar/Views/ResetHistoryView.swift \
  Sources/CodexRadar/Resources/en.lproj/Localizable.strings \
  Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings \
  Tests/CodexRadarTests/ResetHistoryPresentationTests.swift \
  Tests/CodexRadarTests/AppLocalizationTests.swift
git commit -m "feat: render dashboard history ranges"
```

Expected: presentation and localization tests pass.

---

### Task 5: Integrate and Verify the Dashboard

**Files:**
- Review: `Sources/CodexRadar/Views/ContentView.swift`
- Review: `Sources/CodexRadar/Views/TokenUsageView.swift`
- Review: all files modified in Tasks 1–4

**Interfaces:**
- Verifies that existing Dashboard lifecycle signals still drive the new store.
- Verifies end-to-end compatibility with the deployed backend range contract.

- [ ] **Step 1: Confirm ContentView wiring remains sufficient**

Verify that `ContentView` still calls:

- `dashboardDidAppear(timeZone:lastResetAt:)` when Dashboard opens;
- `dashboardDidDisappear()` when it closes;
- `refresh(timeZone:)` after a relevant time-zone change;
- `lastResetDidChange(_:timeZone:)` when the forecast's last successful reset changes.

Do not add an application-start history request. Do not add a timer in `ContentView`; the store owns the boundary wait.

- [ ] **Step 2: Run the complete local verification**

```bash
swift format lint --recursive Sources Tests
swift test
swift build
```

Expected: formatting, all tests, and the debug build pass.

- [ ] **Step 3: Scan for obsolete protocol state**

```bash
rg -n 'availableYears|available_years|pendingYear|selectYear|history\\.year|name: "year"' \
  Sources Tests
```

Expected: no matches.

```bash
rg -n 'ResetHistoryRange|rangeDescription|nextBoundary|pendingRange' Sources Tests
```

Expected: model, service, store, presentation, view, and tests all reference the new range flow.

- [ ] **Step 4: Perform a manual Dashboard acceptance pass**

Run the app against a backend that already serves the approved range contract:

```bash
swift run CodexRadar
```

Verify:

1. No `/v1/history` request occurs before Dashboard opens.
2. Initial request contains `time_zone` and omits `range`; six months render with `6M` selected.
3. `3M` and back to `6M` switch immediately without a network request.
4. First `12M` makes one `range=12m` request while keeping the old chart visible.
5. First `All` makes one `range=all` request and lands at the latest month.
6. `All` scrolls horizontally with readable, fixed-width bars.
7. This-week, this-month, recent-five, empty-state and failure-state content remain correct.
8. Token usage remains full width and no Dashboard card is compressed into a sidebar.
9. Closing Dashboard stops pending history work; reopening performs a fresh request.

- [ ] **Step 5: Review the final diff**

```bash
git status --short
git diff --stat HEAD~4..HEAD
git diff --check HEAD~4..HEAD
```

Expected: only history model/service/store/view/tests/resources and this approved feature's support files changed.

- [ ] **Step 6: Record the client handoff**

```bash
git rev-parse HEAD
```

Expected: a commit containing all four client implementation commits, ready for review after backend deployment.
