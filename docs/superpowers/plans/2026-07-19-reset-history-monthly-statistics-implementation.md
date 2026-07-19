# Reset History and Monthly Statistics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 在 macOS 客户端中显示服务端权威的最近重置时间，并在 Dashboard 按用户时区展示本周、本月、所选年份十二个月统计和最近五条记录。

**Architecture:** /v1/current.last_reset_at 继续进入现有 DashboardStore，只承担菜单栏最近时间；/v1/history 由独立的 ResetHistoryService 和 ResetHistoryStore 管理，只在 Dashboard 活动时加载。纯 presentation 类型负责协议状态到本地化 UI 的映射，SwiftUI 视图不复制协议判断。

**Tech Stack:** Swift 6、SwiftUI、Swift Charts、Foundation、Swift Package Manager、Swift Testing、macOS 14+

## Global Constraints

- 服务端是历史的唯一权威来源，客户端不得根据 forecast 自行生成事件。
- /v1/current v1.1 的 last_reset_at 必须存在但可为 null；客户端必须区分旧响应字段缺失和明确 null。
- 菜单栏不请求 /v1/history；history 只在 Dashboard 活动时请求且不轮询。
- Dashboard 固定展示本周、本月、所选年份十二个月和最近五条，不提供分页。
- 客户端传入 IANA 时区，不自行重算服务端 count。
- 第一版不增加磁盘缓存或 UserDefaults 历史缓存。
- forecast、history、token usage 保持独立加载和错误状态。
- 快速切换年份、退出 Dashboard 和重复刷新不得让旧响应覆盖新状态。
- 保持 macOS 14、300pt 菜单栏宽度，不新增 Swift package 依赖。
- 不改变现有 forecast 状态机、通知策略或 token 聚合语义。
- 所有代码、标识符、注释和提交信息使用 English；文案提供 English 和简体中文。

## File Map

- Create Sources/CodexRadar/Support/APIJSONCoding.swift: 共享 ISO-8601 decoder。
- Modify Sources/CodexRadar/Models/ResetForecast.swift: 区分 missing、null 和具体 last_reset_at。
- Modify Sources/CodexRadar/Models/ResetForecastPresentation.swift and Sources/CodexRadar/Views/MenuBarView.swift: 最近重置展示。
- Create Sources/CodexRadar/Models/ResetHistory.swift and Sources/CodexRadar/Services/ResetHistoryService.swift: history 协议与请求。
- Create Sources/CodexRadar/Stores/ResetHistoryStore.swift: Dashboard 生命周期与请求协调。
- Create Sources/CodexRadar/Models/ResetHistoryPresentation.swift and Sources/CodexRadar/Views/ResetHistoryView.swift: 月份图与最近五条。
- Modify CodexRadarApp.swift, SettingsView.swift, ContentView.swift: 注入、激活、刷新和取消。
- Modify DisplayFormatting.swift, both Localizable.strings files, and README.md。
- Create ResetHistoryDecodingTests.swift, ResetHistoryServiceTests.swift, ResetHistoryStoreTests.swift, ResetHistoryPresentationTests.swift。
- Modify ResetForecastDecodingTests.swift, ResetForecastPresentationTests.swift, AppLocalizationTests.swift。

---

### Task 1: Decode Recent Reset Availability

**Files:**
- Create: Sources/CodexRadar/Support/APIJSONCoding.swift
- Modify: Sources/CodexRadar/Models/ResetForecast.swift
- Modify: Tests/CodexRadarTests/ResetForecastDecodingTests.swift

**Interfaces:**
- Produces: APIJSONCoding.makeDecoder() -> JSONDecoder.
- Produces: LastResetAvailability.unavailable, .none, .resetAt(Date).
- Produces: ResetForecast.lastReset and computed lastResetAt.

- [ ] **Step 1: Write the failing contract test**

Add to ResetForecastDecodingTests:

~~~swift
@Test
func distinguishesMissingNullAndKnownLastReset() throws {
  let missing = try decode(response())
  let none = try decode(response(lastResetField: #", "last_reset_at": null"#))
  let known = try decode(
    response(lastResetField: #", "last_reset_at": "2026-07-19T08:21:34Z""#)
  )

  #expect(missing.lastReset == .unavailable)
  #expect(none.lastReset == .none)
  guard case .resetAt(let resetAt) = known.lastReset else {
    Issue.record("Expected a known reset timestamp.")
    return
  }
  #expect(known.lastResetAt == resetAt)
}
~~~

Extend the private JSON helper with lastResetField: String = "" and append it after posts.

- [ ] **Step 2: Run the focused test and verify RED**

~~~bash
swift test --filter ResetForecastDecodingTests
~~~

Expected: compilation fails because the recent-reset properties do not exist.

- [ ] **Step 3: Extract the shared decoder**

Create APIJSONCoding.swift by moving the existing custom date strategy and both formatter factories out of ResetForecast.swift:

~~~swift
import Foundation

enum APIJSONCoding {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
        ?? ISO8601DateFormatter.withoutFractionalSeconds.date(from: value)
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected an ISO-8601 timestamp."
        )
      }
      return date
    }
    return decoder
  }
}
~~~

Change ResetForecast.decoder to APIJSONCoding.makeDecoder().

- [ ] **Step 4: Implement explicit field availability**

Change ResetForecast from Codable to Decodable; no production code encodes this HTTP response model. Add:

~~~swift
enum LastResetAvailability: Equatable, Sendable {
  case unavailable
  case none
  case resetAt(Date)
}
~~~

Add lastReset: LastResetAvailability = .unavailable to the manual initializer and placeholder. Add the last_reset_at coding key and this branch:

~~~swift
if container.contains(.lastResetAt) {
  if let value = try container.decodeIfPresent(Date.self, forKey: .lastResetAt) {
    lastReset = .resetAt(value)
  } else {
    lastReset = .none
  }
} else {
  lastReset = .unavailable
}

var lastResetAt: Date? {
  guard case .resetAt(let value) = lastReset else { return nil }
  return value
}
~~~

- [ ] **Step 5: Format, verify GREEN, and commit**

~~~bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/Support/APIJSONCoding.swift \
  Sources/CodexRadar/Models/ResetForecast.swift \
  Tests/CodexRadarTests/ResetForecastDecodingTests.swift
swift test --filter ResetForecastDecodingTests
git add Sources/CodexRadar/Support/APIJSONCoding.swift Sources/CodexRadar/Models/ResetForecast.swift Tests/CodexRadarTests/ResetForecastDecodingTests.swift
git commit -m "feat: decode latest reset timestamp"
~~~

Expected: the focused suite passes.

---

### Task 2: Show Recent Reset in the Menu Bar

**Files:**
- Modify: Sources/CodexRadar/Models/ResetForecastPresentation.swift
- Modify: Sources/CodexRadar/Views/MenuBarView.swift
- Modify: both Sources/CodexRadar/Resources/*/Localizable.strings
- Modify: Tests/CodexRadarTests/ResetForecastPresentationTests.swift
- Modify: Tests/CodexRadarTests/AppLocalizationTests.swift

**Interfaces:**
- Consumes: ResetForecast.lastReset from Task 1.
- Produces: ResetForecastPresentation.LastResetDisplay and lastResetDisplay.
- Produces localization keys Fetching reset time, No reset history, Reset time unavailable.

- [ ] **Step 1: Write failing presentation and localization tests**

~~~swift
@Test
func mapsRecentResetIndependentlyFromForecastStaleness() {
  let resetAt = Date(timeIntervalSince1970: 1_753_002_094)
  let presentation = ResetForecastPresentation(
    forecast: presentationForecast(
      status: .announced,
      action: .wait,
      stale: true,
      lastReset: .resetAt(resetAt)
    )
  )
  #expect(presentation.lastResetDisplay == .resetAt(resetAt))
}
~~~

Add lastReset to the test factory. Add an AppLocalizationTests assertion that No reset history maps to 暂无重置记录 in simplified Chinese.

- [ ] **Step 2: Run tests and verify RED**

~~~bash
swift test --filter ResetForecastPresentationTests
swift test --filter AppLocalizationTests
~~~

Expected: presentation compilation fails and the Chinese key falls back to English.

- [ ] **Step 3: Implement presentation mapping**

~~~swift
enum LastResetDisplay: Equatable {
  case unavailable
  case none
  case resetAt(Date)
}

let lastResetDisplay: LastResetDisplay
~~~

Initialize independently from stale:

~~~swift
lastResetDisplay = switch forecast.lastReset {
case .unavailable: .unavailable
case .none: .none
case .resetAt(let value): .resetAt(value)
}
~~~

- [ ] **Step 4: Replace the menu-card detail line**

Render recentResetContent immediately after timeContent. Remove the old detail Text from the .none branch and delete only MenuResetPredictionCard.emptyStateDetailKey:

~~~swift
@ViewBuilder
private var recentResetContent: some View {
  Group {
    switch presentation.lastResetDisplay {
    case .resetAt(let value):
      Text(DisplayFormatting.absoluteDate(value, locale: locale))
    case .none:
      Text("No reset history")
    case .unavailable where isRefreshing:
      Text("Fetching reset time")
    case .unavailable:
      Text("Reset time unavailable")
    }
  }
  .font(.caption.weight(.medium))
  .foregroundStyle(secondaryText)
}
~~~

Do not change the separate Dashboard ResetForecastCard descriptions.

- [ ] **Step 5: Add exact localized values**

~~~text
"Fetching reset time" = "Fetching reset time";
"No reset history" = "No reset history";
"Reset time unavailable" = "Reset time unavailable";
~~~

~~~text
"Fetching reset time" = "正在获取重置时间";
"No reset history" = "暂无重置记录";
"Reset time unavailable" = "重置时间暂不可用";
~~~

- [ ] **Step 6: Format, verify, and commit**

~~~bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place Sources/CodexRadar/Models/ResetForecastPresentation.swift Sources/CodexRadar/Views/MenuBarView.swift Tests/CodexRadarTests/ResetForecastPresentationTests.swift Tests/CodexRadarTests/AppLocalizationTests.swift
swift test --filter ResetForecastPresentationTests
swift test --filter AppLocalizationTests
git add Sources/CodexRadar/Models/ResetForecastPresentation.swift Sources/CodexRadar/Views/MenuBarView.swift Sources/CodexRadar/Resources Tests/CodexRadarTests/ResetForecastPresentationTests.swift Tests/CodexRadarTests/AppLocalizationTests.swift
git commit -m "feat: show latest reset in menu bar"
~~~

Expected: both suites pass and the card contains one recent-reset subtitle.

---

### Task 3: Decode and Fetch /v1/history

**Files:**
- Create: Sources/CodexRadar/Models/ResetHistory.swift
- Create: Sources/CodexRadar/Services/ResetHistoryService.swift
- Create: Tests/CodexRadarTests/ResetHistoryDecodingTests.swift
- Create: Tests/CodexRadarTests/ResetHistoryServiceTests.swift

**Interfaces:**
- Consumes: APIJSONCoding.makeDecoder() and HTTPDataLoader.
- Produces: ResetHistory, ResetHistoryInterval, ResetMonthSummary, ResetHistoryEvent.
- Produces: ResetHistoryService.fetch(timeZoneIdentifier:year:) async throws -> ResetHistory.

- [ ] **Step 1: Write failing decoder tests**

Create a test JSON helper that emits exactly twelve month objects and configurable recent count:

~~~swift
@Test
func decodesTwelveMonthsAndFiveOrFewerRecentEvents() throws {
  let history = try APIJSONCoding.makeDecoder().decode(
    ResetHistory.self,
    from: Data(historyJSON(monthCount: 12, recentCount: 5).utf8)
  )

  #expect(history.year == 2026)
  #expect(history.availableYears == [2026, 2025])
  #expect(history.current.week.count == 2)
  #expect(history.current.month.count == 6)
  #expect(history.months.count == 12)
  #expect(history.recent.count == 5)
}

@Test
func rejectsInvalidCollectionShapes() {
  #expect(throws: DecodingError.self) {
    try APIJSONCoding.makeDecoder().decode(
      ResetHistory.self,
      from: Data(historyJSON(monthCount: 11, recentCount: 2).utf8)
    )
  }
  #expect(throws: DecodingError.self) {
    try APIJSONCoding.makeDecoder().decode(
      ResetHistory.self,
      from: Data(historyJSON(monthCount: 12, recentCount: 6).utf8)
    )
  }
}
~~~

The helper must include schema_version, generated_at, time_zone, year, available_years, current.week, current.month, months, and recent with valid ISO-8601 dates.

Use this concrete helper so every structural test has complete input:

~~~swift
private func historyJSON(monthCount: Int = 12, recentCount: Int = 2) -> String {
  let months = (1...monthCount).map { month in
    let value = String(format: "2026-%02d", month)
    return """
    {"month":"\(value)","from":"2026-01-01T00:00:00Z","to":"2026-02-01T00:00:00Z","count":\(month)}
    """
  }.joined(separator: ",")
  let recent = (1...recentCount).map { index in
    """
    {"id":"reset-\(index)","reset_at":"2026-07-19T08:21:34Z"}
    """
  }.joined(separator: ",")
  return """
  {
    "schema_version":"1.0",
    "generated_at":"2026-07-19T09:00:00Z",
    "time_zone":"Asia/Shanghai",
    "year":2026,
    "available_years":[2026,2025],
    "current":{
      "week":{"from":"2026-07-13T16:00:00Z","to":"2026-07-20T16:00:00Z","count":2},
      "month":{"from":"2026-06-30T16:00:00Z","to":"2026-07-31T16:00:00Z","count":6}
    },
    "months":[\(months)],
    "recent":[\(recent)]
  }
  """
}
~~~

- [ ] **Step 2: Verify decoder tests are RED**

~~~bash
swift test --filter ResetHistoryDecodingTests
~~~

Expected: compilation fails because ResetHistory does not exist.

- [ ] **Step 3: Implement strict response models**

~~~swift
struct ResetHistoryInterval: Decodable, Equatable, Sendable {
  let from: Date
  let to: Date
  let count: Int
}

struct ResetMonthSummary: Decodable, Equatable, Identifiable, Sendable {
  let month: String
  let from: Date
  let to: Date
  let count: Int
  var id: String { month }
}

struct ResetHistoryEvent: Decodable, Equatable, Identifiable, Sendable {
  let id: String
  let resetAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case resetAt = "reset_at"
  }
}

struct ResetHistoryCurrent: Decodable, Equatable, Sendable {
  let week: ResetHistoryInterval
  let month: ResetHistoryInterval
}

struct ResetHistory: Decodable, Equatable, Sendable {
  let schemaVersion: String
  let generatedAt: Date
  let timeZone: String
  let year: Int
  let availableYears: [Int]
  let current: ResetHistoryCurrent
  let months: [ResetMonthSummary]
  let recent: [ResetHistoryEvent]
}
~~~

Give ResetHistory explicit CodingKeys for schema_version, generated_at, time_zone, available_years and the unchanged keys. Its init(from:) must decode every field, construct expected month IDs with (1...12).map { String(format: "%04d-%02d", year, $0) }, and reject invalid time zones, negative counts, intervals where from >= to, month IDs not exactly matching that ordered list, duplicate recent IDs, or recent arrays above five.

- [ ] **Step 4: Write failing request and HTTP mapping tests**

~~~swift
@Test
func sendsTimeZoneAndYear() async throws {
  let recorder = HistoryRequestRecorder()
  let service = ResetHistoryService(
    loader: HTTPDataLoader { request in
      await recorder.record(request)
      return (Data(historyJSON().utf8), response(status: 200, url: request.url!))
    }
  )

  _ = try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", year: 2026)
  let request = try #require(await recorder.request)
  let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))

  #expect(request.url?.path == "/v1/history")
  #expect(components.queryItems?.first(where: { $0.name == "time_zone" })?.value == "Asia/Shanghai")
  #expect(components.queryItems?.first(where: { $0.name == "year" })?.value == "2026")
  #expect(request.timeoutInterval == 15)
}
~~~

Also assert 400 maps to invalidRequest, 503 to unavailable, and other failures to invalidResponse.

- [ ] **Step 5: Implement ResetHistoryService**

~~~swift
enum ResetHistoryServiceError: LocalizedError, Equatable {
  case invalidResponse
  case invalidRequest
  case unavailable
}

struct ResetHistoryService: Sendable {
  let historyURL: URL
  let loader: HTTPDataLoader

  init(
    historyURL: URL = URL(string: "https://codexradar.com/v1/history")!,
    loader: HTTPDataLoader = .live
  ) {
    self.historyURL = historyURL
    self.loader = loader
  }

  func fetch(timeZoneIdentifier: String, year: Int?) async throws -> ResetHistory {
    guard TimeZone(identifier: timeZoneIdentifier) != nil,
      var components = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)
    else {
      throw ResetHistoryServiceError.invalidRequest
    }
    components.queryItems = [URLQueryItem(name: "time_zone", value: timeZoneIdentifier)]
    if let year {
      components.queryItems?.append(URLQueryItem(name: "year", value: String(year)))
    }
    guard let url = components.url else { throw ResetHistoryServiceError.invalidRequest }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await loader.load(request)
    guard let http = response as? HTTPURLResponse else {
      throw ResetHistoryServiceError.invalidResponse
    }
    switch http.statusCode {
    case 200..<300:
      let history = try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: data)
      guard history.timeZone == timeZoneIdentifier,
        year.map({ history.year == $0 }) ?? true
      else {
        throw ResetHistoryServiceError.invalidResponse
      }
      return history
    case 400:
      throw ResetHistoryServiceError.invalidRequest
    case 503:
      throw ResetHistoryServiceError.unavailable
    default:
      throw ResetHistoryServiceError.invalidResponse
    }
  }
}
~~~

- [ ] **Step 6: Format, verify, and commit**

~~~bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place Sources/CodexRadar/Models/ResetHistory.swift Sources/CodexRadar/Services/ResetHistoryService.swift Tests/CodexRadarTests/ResetHistoryDecodingTests.swift Tests/CodexRadarTests/ResetHistoryServiceTests.swift
swift test --filter ResetHistoryDecodingTests
swift test --filter ResetHistoryServiceTests
git add Sources/CodexRadar/Models/ResetHistory.swift Sources/CodexRadar/Services/ResetHistoryService.swift Tests/CodexRadarTests/ResetHistoryDecodingTests.swift Tests/CodexRadarTests/ResetHistoryServiceTests.swift
git commit -m "feat: add reset history API client"
~~~

Expected: both focused suites pass.

---

### Task 4: Coordinate Dashboard-Only Loading

**Files:**
- Create: Sources/CodexRadar/Stores/ResetHistoryStore.swift
- Create: Tests/CodexRadarTests/ResetHistoryStoreTests.swift

**Interfaces:**
- Consumes: ResetHistoryService from Task 3.
- Produces published history, pendingYear, isLoading, issue.
- Produces dashboardDidAppear, dashboardDidDisappear, refresh, selectYear, lastResetDidChange.

- [ ] **Step 1: Write failing lifecycle tests**

Cover these cases with a ControlledHistoryFetcher actor:

~~~swift
@Test
func doesNotLoadUntilDashboardAppears() async {
  let fetcher = ControlledHistoryFetcher()
  let store = makeHistoryStore(fetcher: fetcher)
  let zone = TimeZone(identifier: "Asia/Shanghai")!

  store.refresh(timeZone: zone)
  await Task.yield()
  #expect(await fetcher.callCount == 0)

  store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
  for _ in 0..<20 where await fetcher.callCount == 0 { await Task.yield() }
  #expect(await fetcher.callCount == 1)
}

@Test
func failedYearSelectionKeepsCommittedData() async {
  let fetcher = ControlledHistoryFetcher()
  let store = makeHistoryStore(fetcher: fetcher)
  let zone = TimeZone(identifier: "Asia/Shanghai")!

  store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
  await fetcher.completeNext(with: .success(history(year: 2026)))
  await Task.yield()
  store.selectYear(2025, timeZone: zone)
  await fetcher.completeNext(with: .failure(.unavailable))
  await Task.yield()

  #expect(store.history?.year == 2026)
  #expect(store.pendingYear == nil)
  #expect(store.issue != nil)
}
~~~

Add tests proving: a newer year request wins over an older response; a changed lastResetAt reloads only when active; disappearance cancels and blocks commits; a changed time zone reloads the committed year.

- [ ] **Step 2: Verify store tests are RED**

~~~bash
swift test --filter ResetHistoryStoreTests
~~~

Expected: compilation fails because ResetHistoryStore does not exist.

- [ ] **Step 3: Implement store state and lifecycle**

~~~swift
@MainActor
final class ResetHistoryStore: ObservableObject {
  typealias FetchHistory = @Sendable (String, Int?) async throws -> ResetHistory

  @Published private(set) var history: ResetHistory?
  @Published private(set) var pendingYear: Int?
  @Published private(set) var isLoading = false
  @Published private(set) var issue: String?

  private let fetchHistory: FetchHistory
  private let formatIssue: @MainActor @Sendable () -> String
  private var isDashboardActive = false
  private var lastObservedResetAt: Date?
  private var activeQuery: Query?
  private var needsTrailingReload = false
  private var loadTask: Task<Void, Never>?
  private var generation: UInt64 = 0

  private struct Query: Equatable, Sendable {
    let timeZoneIdentifier: String
    let year: Int
  }
}
~~~

The live initializer wraps ResetHistoryService and localizes Reset history is temporarily unavailable. Public methods must:
- On appear: mark active, remember lastResetAt, request committed year or current local year.
- On disappear: increment generation, cancel task, clear active query/pending/loading but retain history.
- On refresh: no-op unless active, then request committed year.
- On selectYear: reject values not in availableYears.
- On lastResetDidChange: update the remembered value and request only if active and changed.

Implement those rules with these exact signatures:

~~~swift
func dashboardDidAppear(timeZone: TimeZone, lastResetAt: Date?) {
  isDashboardActive = true
  lastObservedResetAt = lastResetAt
  request(year: history?.year ?? Self.currentYear(in: timeZone), timeZone: timeZone)
}

func dashboardDidDisappear() {
  isDashboardActive = false
  generation &+= 1
  loadTask?.cancel()
  loadTask = nil
  activeQuery = nil
  needsTrailingReload = false
  pendingYear = nil
  isLoading = false
}

func refresh(timeZone: TimeZone) {
  guard isDashboardActive else { return }
  request(year: history?.year ?? Self.currentYear(in: timeZone), timeZone: timeZone)
}

func selectYear(_ year: Int, timeZone: TimeZone) {
  guard isDashboardActive, history?.availableYears.contains(year) == true else { return }
  request(year: year, timeZone: timeZone)
}

func lastResetDidChange(_ resetAt: Date?, timeZone: TimeZone) {
  guard resetAt != lastObservedResetAt else { return }
  lastObservedResetAt = resetAt
  guard isDashboardActive else { return }
  request(year: history?.year ?? Self.currentYear(in: timeZone), timeZone: timeZone)
}

private static func currentYear(in timeZone: TimeZone) -> Int {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  return calendar.component(.year, from: .now)
}
~~~

- [ ] **Step 4: Implement cancel-and-replace coordination**

~~~swift
private func request(year: Int, timeZone: TimeZone) {
  let query = Query(timeZoneIdentifier: timeZone.identifier, year: year)
  if activeQuery == query {
    needsTrailingReload = true
    return
  }

  generation &+= 1
  let requestGeneration = generation
  loadTask?.cancel()
  activeQuery = query
  pendingYear = history?.year == year ? nil : year
  isLoading = true
  let fetchHistory = fetchHistory

  loadTask = Task { [weak self] in
    do {
      let result = try await fetchHistory(query.timeZoneIdentifier, query.year)
      guard !Task.isCancelled, let self, requestGeneration == generation else { return }
      history = result
      issue = nil
      finish(query)
    } catch is CancellationError {
      guard let self, requestGeneration == generation else { return }
      finish(query)
    } catch {
      guard !Task.isCancelled, let self, requestGeneration == generation else { return }
      issue = formatIssue()
      finish(query)
    }
  }
}
~~~

finish must clear activeQuery, pendingYear, isLoading and loadTask only when the passed query still matches. If needsTrailingReload is true and the Dashboard remains active, clear that flag and immediately request the same query once more; multiple identical triggers collapse into this single trailing reload. A different query cancels and supersedes the current query and clears the obsolete trailing flag. Add a test where lastResetAt changes during the initial request, complete that request with an old snapshot, and assert exactly one second request starts and commits the new snapshot.

- [ ] **Step 5: Format, verify, and commit**

~~~bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place Sources/CodexRadar/Stores/ResetHistoryStore.swift Tests/CodexRadarTests/ResetHistoryStoreTests.swift
swift test --filter ResetHistoryStoreTests
git add Sources/CodexRadar/Stores/ResetHistoryStore.swift Tests/CodexRadarTests/ResetHistoryStoreTests.swift
git commit -m "feat: coordinate reset history loading"
~~~

Expected: lifecycle, retention, supersession and cancellation tests pass.

---

### Task 5: Build and Wire the Statistics Dashboard

**Files:**
- Create: Sources/CodexRadar/Models/ResetHistoryPresentation.swift
- Create: Sources/CodexRadar/Views/ResetHistoryView.swift
- Modify: Sources/CodexRadar/Support/DisplayFormatting.swift
- Modify: Sources/CodexRadar/App/CodexRadarApp.swift
- Modify: Sources/CodexRadar/Views/SettingsView.swift
- Modify: Sources/CodexRadar/Views/ContentView.swift
- Modify: both localization files
- Create: Tests/CodexRadarTests/ResetHistoryPresentationTests.swift
- Modify: Tests/CodexRadarTests/AppLocalizationTests.swift

**Interfaces:**
- Consumes: ResetHistoryStore and ResetHistory.
- Produces: ResetHistoryPresentation with twelve Month rows and at most five Recent rows.
- Produces: ResetHistoryView(store:timeZone:).
- Produces Dashboard activation, cancellation, total refresh, year selection and last-reset refresh wiring.

- [ ] **Step 1: Write failing presentation tests**

~~~swift
@Test
func mapsStatisticsAndRecentRows() {
  let presentation = ResetHistoryPresentation(
    history: history(year: 2026, recentCount: 5),
    locale: Locale(identifier: "en_US"),
    timeZone: TimeZone(identifier: "Asia/Shanghai")!
  )

  #expect(presentation.weekCount == 2)
  #expect(presentation.monthCount == 6)
  #expect(presentation.months.count == 12)
  #expect(presentation.months.first?.label == "Jan")
  #expect(presentation.months.last?.label == "Dec")
  #expect(presentation.recent.count == 5)
  #expect(presentation.availableYears == [2026, 2025])
}
~~~

Add localization assertions for Reset statistics and This week in both languages.

- [ ] **Step 2: Verify presentation tests are RED**

~~~bash
swift test --filter ResetHistoryPresentationTests
swift test --filter AppLocalizationTests
~~~

Expected: presentation compilation fails and new localization keys are absent.

- [ ] **Step 3: Implement explicit-time-zone formatting and presentation**

Extend absoluteDate source-compatibly:

~~~swift
static func absoluteDate(
  _ date: Date,
  locale: Locale = .current,
  timeZone: TimeZone = .autoupdatingCurrent
) -> String {
  date.formatted(
    Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
  )
}
~~~

Implement ResetHistoryPresentation with these exact outputs:

~~~swift
struct ResetHistoryPresentation {
  struct Month: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
  }

  struct Recent: Identifiable, Equatable {
    let id: String
    let dateTime: String
  }

  let year: Int
  let availableYears: [Int]
  let weekCount: Int
  let monthCount: Int
  let months: [Month]
  let recent: [Recent]

  init(history: ResetHistory, locale: Locale, timeZone: TimeZone) {
    year = history.year
    availableYears = history.availableYears
    weekCount = history.current.week.count
    monthCount = history.current.month.count
    months = history.months.map { summary in
      Month(
        id: summary.id,
        label: summary.from.formatted(
          Date.FormatStyle().month(.abbreviated).locale(locale).timeZone(timeZone)
        ),
        count: summary.count
      )
    }
    recent = history.recent.map { event in
      Recent(
        id: event.id,
        dateTime: DisplayFormatting.absoluteDate(
          event.resetAt,
          locale: locale,
          timeZone: timeZone
        )
      )
    }
  }
}
~~~

- [ ] **Step 4: Build ResetHistoryView**

The view order is fixed:

~~~swift
VStack(alignment: .leading, spacing: 18) {
  header
  HStack(spacing: 12) {
    ResetCountTile(title: "This week", count: presentation.weekCount)
    ResetCountTile(title: "This month", count: presentation.monthCount)
  }
  monthlyChart
  recentList
  historyIssue
}
.padding(22)
.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
~~~

Requirements:
- Header contains Reset statistics and a year Picker driven by availableYears.
- Picker calls store.selectYear(_:timeZone:).
- During a pending year switch, replace only the chart with ProgressView so old data is never labeled as the new year.
- Chart uses twelve categorical BarMark values, annotates every count, and has a Monthly resets accessibility label.
- Recent list renders at most five rows and shows No reset history when empty.
- First-load failure shows Reset history unavailable with a retry button calling store.refresh.
- A refresh failure with existing data retains all content and adds a non-blocking orange issue label.

- [ ] **Step 5: Add the exact localization set**

Add English and Chinese values for:
- Reset statistics / 重置统计
- This week / 本周
- Monthly resets / 每月重置次数
- Recent resets / 最近重置
- Latest 5 / 最近 5 条
- Loading reset statistics / 正在加载重置统计
- Reset history unavailable / 重置历史暂不可用
- Retry / 重试
- Reset history is temporarily unavailable. / 重置历史暂时不可用。

Reuse existing This month, Year, and No reset history keys.

- [ ] **Step 6: Inject and activate the history store**

In CodexRadarApp create one StateObject ResetHistoryStore and pass it only through SettingsView to ContentView. Do not pass it to MenuBarView.

In ContentView, place ResetHistoryView between ResetForecastCard and TokenUsageView. Add:

~~~swift
@Environment(\.timeZone) private var timeZone

.onAppear {
  store.startMonitoring()
  historyStore.dashboardDidAppear(
    timeZone: timeZone,
    lastResetAt: store.forecast.lastResetAt
  )
}
.onDisappear {
  historyStore.dashboardDidDisappear()
}
.onChange(of: timeZone.identifier) {
  historyStore.refresh(timeZone: timeZone)
}
.onChange(of: store.forecast.lastResetAt) {
  historyStore.lastResetDidChange(store.forecast.lastResetAt, timeZone: timeZone)
}
~~~

The toolbar refresh starts store.refresh() and historyStore.refresh(timeZone:) together. Disable it only while DashboardStore is refreshing; ResetHistoryStore coalesces an overlapping refresh and keeps its loading state local. Keep the existing token overlay tied only to DashboardStore.

Use this action so the forecast/token refresh remains awaited while history starts independently through its own store task:

~~~swift
Button {
  historyStore.refresh(timeZone: timeZone)
  Task { await store.refresh() }
} label: {
  Label("Refresh", systemImage: "arrow.clockwise")
}
.disabled(store.isRefreshing)
~~~

- [ ] **Step 7: Format, verify focused suites, build, and commit**

~~~bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place Sources/CodexRadar/Models/ResetHistoryPresentation.swift Sources/CodexRadar/Views/ResetHistoryView.swift Sources/CodexRadar/Support/DisplayFormatting.swift Sources/CodexRadar/App/CodexRadarApp.swift Sources/CodexRadar/Views/SettingsView.swift Sources/CodexRadar/Views/ContentView.swift Tests/CodexRadarTests/ResetHistoryPresentationTests.swift Tests/CodexRadarTests/AppLocalizationTests.swift
swift test --filter ResetHistoryPresentationTests
swift test --filter ResetHistoryStoreTests
swift test --filter AppLocalizationTests
swift build
git add Sources/CodexRadar Tests/CodexRadarTests
git commit -m "feat: add reset statistics dashboard"
~~~

Expected: focused suites pass and the executable builds without warnings.

---

### Task 6: Document and Verify the Complete Feature

**Files:**
- Modify: README.md
- Verify: every file from Tasks 1-5

**Interfaces:**
- Consumes: completed current, history, store, UI and localization slices.
- Produces: documented, formatted, tested and review-ready client implementation.

- [ ] **Step 1: Update README features**

Add:

~~~markdown
- 从 /v1/current 展示服务端确认的最近一次重置时间；旧协议缺字段、明确无历史与暂时不可用使用不同状态。
- Dashboard 打开时读取 /v1/history，按用户时区展示本周、本月、所选年份十二个月统计和最近五次重置。
~~~

- [ ] **Step 2: Run complete formatting and whitespace checks**

~~~bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/Support/APIJSONCoding.swift \
  Sources/CodexRadar/Models/ResetForecast.swift \
  Sources/CodexRadar/Models/ResetForecastPresentation.swift \
  Sources/CodexRadar/Models/ResetHistory.swift \
  Sources/CodexRadar/Models/ResetHistoryPresentation.swift \
  Sources/CodexRadar/Services/ResetHistoryService.swift \
  Sources/CodexRadar/Stores/ResetHistoryStore.swift \
  Sources/CodexRadar/Views/MenuBarView.swift \
  Sources/CodexRadar/Views/ResetHistoryView.swift \
  Sources/CodexRadar/Views/ContentView.swift \
  Sources/CodexRadar/Views/SettingsView.swift \
  Sources/CodexRadar/App/CodexRadarApp.swift \
  Sources/CodexRadar/Support/DisplayFormatting.swift \
  Tests/CodexRadarTests/ResetForecastDecodingTests.swift \
  Tests/CodexRadarTests/ResetForecastPresentationTests.swift \
  Tests/CodexRadarTests/ResetHistoryDecodingTests.swift \
  Tests/CodexRadarTests/ResetHistoryServiceTests.swift \
  Tests/CodexRadarTests/ResetHistoryStoreTests.swift \
  Tests/CodexRadarTests/ResetHistoryPresentationTests.swift \
  Tests/CodexRadarTests/AppLocalizationTests.swift
git diff --check
~~~

Expected: formatting succeeds and no whitespace errors are reported.

- [ ] **Step 3: Run the complete test suite and build**

~~~bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift build
~~~

Expected: all tests pass with zero failures and the debug build succeeds.

- [ ] **Step 4: Perform manual UI verification**

~~~bash
./script/build_and_run.sh
~~~

Verify:
- Menu bar at 300pt shows a localized absolute reset time without a label.
- Missing field shows unavailable, explicit null shows no history, and a known time survives stale forecast.
- Dashboard opening starts history; navigating away cancels it and causes no background polling.
- Order is forecast, week/month cards, twelve-month chart, recent five, token usage.
- Year selection changes only history and reverts to committed data on failure.
- English and Chinese are readable in Light and Dark Mode.
- Month bars and recent rows have useful VoiceOver labels.

- [ ] **Step 5: Run project-local autoreview**

~~~bash
.agents/skills/autoreview/scripts/autoreview --mode branch --base main
~~~

Expected: no accepted/actionable findings. Fix and re-run any accepted finding before committing.

- [ ] **Step 6: Commit documentation**

~~~bash
git add README.md
git commit -m "docs: describe reset history statistics"
~~~
