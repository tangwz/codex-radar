# Token Usage Cache and Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Token 用量在有缓存时于 300 ms 内显示，只增量解析变化日志，并让日、月、年筛选正确驱动当前周期指标与悬浮柱状图。

**Architecture:** 新增 `TokenUsageRepository` actor，使用小型 snapshot 与文件级 manifest 两层 property-list 缓存，在后台比较文件指纹并复用未变化文件的解析结果。UI 只消费预聚合的 `TokenUsageSnapshot`；`DashboardStore` 协调缓存首屏、后台刷新和错误状态，Swift Charts overlay 只负责把鼠标位置映射到最近分桶。

**Tech Stack:** Swift 6、SwiftUI、Swift Charts、Foundation、Swift Testing、macOS 14+

## Global Constraints

- 保持 macOS 14 最低版本和现有 Swift Package 依赖，不增加第三方库或 SQLite。
- 缓存位于标准 macOS `Caches` 目录，是可重建数据，不成为统计权威来源。
- 有有效 snapshot 时，Dashboard 的 Token 区域目标在 300 ms 内显示。
- 所有 JSONL I/O、解析、去重与聚合均在主 actor 外执行。
- 日、月、年顶部指标分别表示今天、本月和今年。
- 图表固定展示连续 14 个自然日、12 个自然月和 6 个自然年，并补齐零值分桶。
- Dashboard 只展示 Total、Input 和 Output；`cachedInputTokens` 仅保留在解析与去重内部。
- 不增加实时文件监听、自定义日期范围或新的 Token 统计口径。
- 所有代码、注释、标识符、测试名与提交信息使用 English。

---

## File Map

### Create

- `Sources/CodexRadar/Models/TokenUsageSnapshot.swift`：UI 快照、连续分桶和当前周期汇总。
- `Sources/CodexRadar/Models/TokenUsagePresentation.swift`：周期选择后的纯展示模型与最近柱选择。
- `Sources/CodexRadar/Services/TokenUsageCacheStore.swift`：版本化 property-list snapshot/manifest 读写。
- `Sources/CodexRadar/Services/TokenUsageRepository.swift`：缓存首屏、manifest diff、稳定文件解析和刷新结果。
- `Tests/CodexRadarTests/TokenUsageSnapshotTests.swift`：自然周期、零值分桶与汇总口径。
- `Tests/CodexRadarTests/TokenUsageCacheStoreTests.swift`：缓存命中、损坏和版本失效。
- `Tests/CodexRadarTests/TokenUsageRepositoryTests.swift`：增量扫描、移动、失败保留和不稳定文件。
- `Tests/CodexRadarTests/DashboardStoreTokenUsageTests.swift`：缓存先发布、后台替换和 generation 保护。
- `Tests/CodexRadarTests/TokenUsagePresentationTests.swift`：筛选映射和最近柱选择。

### Modify

- `Sources/CodexRadar/Models/TokenUsage.swift`：让原始事件可缓存，并在迁移完成后删除旧 UI 聚合类型。
- `Sources/CodexRadar/Services/CodexSessionScanner.swift`：拆分发现、指纹、单文件解析和全局去重。
- `Sources/CodexRadar/Stores/DashboardStore.swift`：发布 snapshot，接入 Repository，维护 Token issue 槽位。
- `Sources/CodexRadar/Views/ContentView.swift`：传递 snapshot，调整加载态并在时区变化时刷新 Token 快照。
- `Sources/CodexRadar/Views/MenuBarView.swift`：从 snapshot 读取 Today 与 This month。
- `Sources/CodexRadar/Views/TokenUsageView.swift`：三张指标卡、连续柱状图和 hover tooltip。
- `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`：增加 Token 缓存错误与图表无障碍文案，移除废弃 Cached 文案。
- `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`：同步简体中文。
- `Tests/CodexRadarTests/CodexSessionParserTests.swift`：迁移旧 aggregator 测试。
- `Tests/CodexRadarTests/CodexSessionScannerTests.swift`：覆盖单文件 API 与去重兼容。
- `Tests/CodexRadarTests/DashboardStoreForecastTests.swift`：更新测试构造器。
- `Tests/CodexRadarTests/MenuActionLayoutTests.swift`：更新测试构造器。
- `Tests/CodexRadarTests/MenuBarControllerTests.swift`：更新测试构造器。
- `Tests/CodexRadarTests/AppLocalizationTests.swift`：覆盖新增文案。
- `README.md`：说明增量本地缓存与新的展示口径。

---

### Task 1: Build the immutable Token usage snapshot

**Files:**

- Create: `Sources/CodexRadar/Models/TokenUsageSnapshot.swift`
- Create: `Tests/CodexRadarTests/TokenUsageSnapshotTests.swift`
- Modify: `Sources/CodexRadar/Models/TokenUsage.swift`

**Interfaces:**

- Consumes: `[TokenUsageEvent]`, `Date`, `TimeZone`
- Produces: `TokenUsageSnapshotBuilder.make(events:at:timeZone:) -> TokenUsageSnapshot`
- Produces: `TokenUsageSnapshot.buckets(for:) -> [TokenUsageChartBucket]`
- Produces: `TokenUsageSnapshot.metrics(for:) -> TokenUsageMetrics`

- [ ] **Step 1: Write failing snapshot tests**

Create `Tests/CodexRadarTests/TokenUsageSnapshotTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexRadar

struct TokenUsageSnapshotTests {
  @Test
  func usesCurrentNaturalPeriodForMetricsInsteadOfAllHistory() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-07-15T12:00:00Z")
    let events = [
      event("2025-12-01T12:00:00Z", input: 1_000, output: 100),
      event("2026-07-01T12:00:00Z", input: 200, output: 20),
      event("2026-07-15T08:00:00Z", input: 30, output: 3),
    ]

    let snapshot = TokenUsageSnapshotBuilder.make(
      events: events,
      at: now,
      timeZone: timeZone
    )

    #expect(snapshot.metrics(for: .day) == TokenUsageMetrics(inputTokens: 30, outputTokens: 3))
    #expect(
      snapshot.metrics(for: .month)
        == TokenUsageMetrics(inputTokens: 230, outputTokens: 23)
    )
    #expect(
      snapshot.metrics(for: .year)
        == TokenUsageMetrics(inputTokens: 230, outputTokens: 23)
    )
  }

  @Test
  func createsContinuousWindowsAndFillsMissingPeriodsWithZero() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-07-15T12:00:00Z")
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [event("2026-07-13T08:00:00Z", input: 40, output: 4)],
      at: now,
      timeZone: timeZone
    )

    #expect(snapshot.dailyBuckets.count == 14)
    #expect(snapshot.monthlyBuckets.count == 12)
    #expect(snapshot.yearlyBuckets.count == 6)
    #expect(snapshot.dailyBuckets.suffix(3).map(\.totalTokens) == [44, 0, 0])
    #expect(snapshot.hasUsageData)
  }

  @Test
  func distinguishesNoUsageFromAZeroCurrentPeriod() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-07-15T12:00:00Z")
    let empty = TokenUsageSnapshotBuilder.make(events: [], at: now, timeZone: timeZone)
    let historical = TokenUsageSnapshotBuilder.make(
      events: [event("2020-01-01T00:00:00Z", input: 10, output: 1)],
      at: now,
      timeZone: timeZone
    )

    #expect(!empty.hasUsageData)
    #expect(historical.hasUsageData)
    #expect(historical.metrics(for: .day) == .zero)
  }

  private func event(
    _ timestamp: String,
    input: Int,
    output: Int
  ) -> TokenUsageEvent {
    TokenUsageEvent(
      timestamp: ISO8601DateFormatter().date(from: timestamp)!,
      inputTokens: input,
      cachedInputTokens: 0,
      outputTokens: output
    )
  }

  private func date(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
swift test --filter TokenUsageSnapshotTests
```

Expected: compilation fails because `TokenUsageSnapshotBuilder`, `TokenUsageSnapshot`, and `TokenUsageMetrics` do not exist.

- [ ] **Step 3: Make raw events cacheable**

Change the declaration in `Sources/CodexRadar/Models/TokenUsage.swift`:

```swift
struct TokenUsageEvent: Codable, Equatable, Sendable {
```

Do not remove `cachedInputTokens`, `turnID`, `model`, or `eventIndex`.

- [ ] **Step 4: Implement the snapshot model and builder**

Create `Sources/CodexRadar/Models/TokenUsageSnapshot.swift`:

```swift
import Foundation

enum TokenUsageCacheVersion {
  static let schema = 1
  static let parser = 1
}

struct TokenUsageMetrics: Codable, Equatable, Sendable {
  let inputTokens: Int
  let outputTokens: Int

  static let zero = TokenUsageMetrics(inputTokens: 0, outputTokens: 0)

  var totalTokens: Int {
    inputTokens + outputTokens
  }
}

struct TokenUsageChartBucket: Codable, Equatable, Identifiable, Sendable {
  let startDate: Date
  let inputTokens: Int
  let outputTokens: Int

  var id: Date { startDate }
  var totalTokens: Int { inputTokens + outputTokens }
  var metrics: TokenUsageMetrics {
    TokenUsageMetrics(inputTokens: inputTokens, outputTokens: outputTokens)
  }
}

struct TokenUsageSnapshot: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let parserVersion: Int
  let generatedAt: Date
  let timeZoneIdentifier: String
  let hasUsageData: Bool
  let dailyBuckets: [TokenUsageChartBucket]
  let monthlyBuckets: [TokenUsageChartBucket]
  let yearlyBuckets: [TokenUsageChartBucket]

  var isCompatible: Bool {
    schemaVersion == TokenUsageCacheVersion.schema
      && parserVersion == TokenUsageCacheVersion.parser
  }

  func buckets(for period: TokenUsagePeriod) -> [TokenUsageChartBucket] {
    switch period {
    case .day: dailyBuckets
    case .month: monthlyBuckets
    case .year: yearlyBuckets
    }
  }

  func metrics(for period: TokenUsagePeriod) -> TokenUsageMetrics {
    buckets(for: period).last?.metrics ?? .zero
  }
}

enum TokenUsageSnapshotBuilder {
  static func make(
    events: [TokenUsageEvent],
    at date: Date,
    timeZone: TimeZone
  ) -> TokenUsageSnapshot {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    return TokenUsageSnapshot(
      schemaVersion: TokenUsageCacheVersion.schema,
      parserVersion: TokenUsageCacheVersion.parser,
      generatedAt: date,
      timeZoneIdentifier: timeZone.identifier,
      hasUsageData: !events.isEmpty,
      dailyBuckets: makeBuckets(
        events: events,
        period: .day,
        count: 14,
        at: date,
        calendar: calendar
      ),
      monthlyBuckets: makeBuckets(
        events: events,
        period: .month,
        count: 12,
        at: date,
        calendar: calendar
      ),
      yearlyBuckets: makeBuckets(
        events: events,
        period: .year,
        count: 6,
        at: date,
        calendar: calendar
      )
    )
  }

  private static func makeBuckets(
    events: [TokenUsageEvent],
    period: TokenUsagePeriod,
    count: Int,
    at date: Date,
    calendar: Calendar
  ) -> [TokenUsageChartBucket] {
    guard
      let currentStart = calendar.dateInterval(
        of: period.calendarComponent,
        for: date
      )?.start
    else {
      return []
    }

    let starts = (0..<count).reversed().compactMap {
      calendar.date(byAdding: period.calendarComponent, value: -$0, to: currentStart)
    }
    let visibleStarts = Set(starts)
    var grouped: [Date: TokenUsageMetrics] = [:]

    for event in events {
      guard
        let start = calendar.dateInterval(
          of: period.calendarComponent,
          for: event.timestamp
        )?.start,
        visibleStarts.contains(start)
      else {
        continue
      }
      let previous = grouped[start, default: .zero]
      grouped[start] = TokenUsageMetrics(
        inputTokens: previous.inputTokens + event.inputTokens,
        outputTokens: previous.outputTokens + event.outputTokens
      )
    }

    return starts.map { start in
      let metrics = grouped[start, default: .zero]
      return TokenUsageChartBucket(
        startDate: start,
        inputTokens: metrics.inputTokens,
        outputTokens: metrics.outputTokens
      )
    }
  }
}
```

- [ ] **Step 5: Run focused and full model tests**

Run:

```bash
swift test --filter TokenUsageSnapshotTests
swift test --filter CodexSessionParserTests
```

Expected: both commands pass.

- [ ] **Step 6: Commit the snapshot model**

```bash
git add Sources/CodexRadar/Models/TokenUsage.swift Sources/CodexRadar/Models/TokenUsageSnapshot.swift Tests/CodexRadarTests/TokenUsageSnapshotTests.swift
git commit -m "feat: add token usage snapshots"
```

---

### Task 2: Split session scanning into file-level operations

**Files:**

- Modify: `Sources/CodexRadar/Services/CodexSessionScanner.swift`
- Modify: `Tests/CodexRadarTests/CodexSessionScannerTests.swift`

**Interfaces:**

- Consumes: `CodexSessionParser`, `JSONLLineReader`
- Produces: `CodexSessionScanner.discoverFiles(codexHome:)`
- Produces: `CodexSessionScanner.fingerprint(for:)`
- Produces: `CodexSessionScanner.parseFile(at:)`
- Produces: `CodexSessionScanner.deduplicatedEvents(from:)`
- Produces: `TokenUsageManifest` and `CodexSessionFileRecord` for the cache layer

- [ ] **Step 1: Add failing file-level scanner tests**

Append to `Tests/CodexRadarTests/CodexSessionScannerTests.swift`:

```swift
@Test
func discoversAndParsesOneSessionFile() throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "sessions/2026/07/28/session.jsonl")
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  let contents = """
    {"timestamp":"2026-07-28T00:00:00Z","type":"session_meta","payload":{"session_id":"session-1"}}
    {"timestamp":"2026-07-28T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
    """
  try Data(contents.utf8).write(to: file)

  let scanner = CodexSessionScanner()
  let files = try scanner.discoverFiles(codexHome: root)
  let parsed = try scanner.parseFile(at: try #require(files.first).url)

  #expect(files.count == 1)
  #expect(parsed.sessionID == "session-1")
  #expect(parsed.events.map(\.totalTokens) == [110])
}

@Test
func treatsAPathChangeWithTheSameResourceAsReusableContent() {
  let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let active = CodexSessionFileFingerprint(
    path: "/tmp/sessions/a.jsonl",
    resourceIdentifier: "resource-1",
    size: 100,
    modificationDate: modifiedAt
  )
  let archived = CodexSessionFileFingerprint(
    path: "/tmp/archived_sessions/a.jsonl",
    resourceIdentifier: "resource-1",
    size: 100,
    modificationDate: modifiedAt
  )

  #expect(active.hasSameContent(as: archived))
  #expect(active.cacheIdentity == archived.cacheIdentity)
}
```

- [ ] **Step 2: Run the scanner tests and verify they fail**

Run:

```bash
swift test --filter CodexSessionScannerTests
```

Expected: compilation fails because the file descriptor, fingerprint, and single-file APIs do not exist.

- [ ] **Step 3: Add cache records and file-level APIs**

Replace `Sources/CodexRadar/Services/CodexSessionScanner.swift` with an implementation that retains the existing `scan(codexHome:)` wrapper and adds these exact public-internal types:

```swift
import Foundation

struct CodexSessionFileFingerprint: Codable, Equatable, Sendable {
  let path: String
  let resourceIdentifier: String?
  let size: Int64
  let modificationDate: Date

  var cacheIdentity: String {
    resourceIdentifier.map { "resource:\($0)" } ?? "path:\(path)"
  }

  func hasSameContent(as other: Self) -> Bool {
    guard size == other.size, modificationDate == other.modificationDate else {
      return false
    }
    if let resourceIdentifier, let otherIdentifier = other.resourceIdentifier {
      return resourceIdentifier == otherIdentifier
    }
    return path == other.path
  }
}

struct CodexSessionFileDescriptor: Equatable, Sendable {
  let url: URL
  let fingerprint: CodexSessionFileFingerprint
}

struct ParsedCodexSessionFile: Equatable, Sendable {
  let sessionID: String?
  let events: [TokenUsageEvent]
}

struct CodexSessionFileRecord: Codable, Equatable, Sendable {
  let fingerprint: CodexSessionFileFingerprint
  let sessionID: String?
  let events: [TokenUsageEvent]
}

struct TokenUsageManifest: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let parserVersion: Int
  let files: [CodexSessionFileRecord]

  init(files: [CodexSessionFileRecord]) {
    schemaVersion = TokenUsageCacheVersion.schema
    parserVersion = TokenUsageCacheVersion.parser
    self.files = files
  }

  var isCompatible: Bool {
    schemaVersion == TokenUsageCacheVersion.schema
      && parserVersion == TokenUsageCacheVersion.parser
  }
}

struct CodexSessionScanner: Sendable {
  func scan(codexHome: URL = Self.defaultCodexHome()) throws -> [TokenUsageEvent] {
    let records = try discoverFiles(codexHome: codexHome).compactMap { descriptor in
      guard let parsed = try? parseFile(at: descriptor.url) else { return nil }
      return CodexSessionFileRecord(
        fingerprint: descriptor.fingerprint,
        sessionID: parsed.sessionID,
        events: parsed.events
      )
    }
    return Self.deduplicatedEvents(from: records)
  }

  func discoverFiles(
    codexHome: URL = Self.defaultCodexHome()
  ) throws -> [CodexSessionFileDescriptor] {
    let roots = [
      codexHome.appending(path: "sessions", directoryHint: .isDirectory),
      codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory),
    ]
    return try roots.flatMap(sessionFiles).sorted {
      $0.fingerprint.path < $1.fingerprint.path
    }
  }

  func fingerprint(for fileURL: URL) throws -> CodexSessionFileFingerprint {
    let values = try fileURL.resourceValues(
      forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey,
      ]
    )
    guard values.isRegularFile == true else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    return CodexSessionFileFingerprint(
      path: fileURL.standardizedFileURL.path,
      resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
      size: Int64(values.fileSize ?? 0),
      modificationDate: values.contentModificationDate ?? .distantPast
    )
  }

  func parseFile(at fileURL: URL) throws -> ParsedCodexSessionFile {
    let parser = CodexSessionParser()
    var state = CodexSessionParser.State()
    var events: [TokenUsageEvent] = []
    try JSONLLineReader().forEachLine(at: fileURL) { line in
      let event = autoreleasepool {
        parser.parse(line: line, state: &state)
      }
      if let event {
        events.append(event)
      }
    }
    return ParsedCodexSessionFile(sessionID: state.sessionID, events: events)
  }

  static func deduplicatedEvents(
    from records: [CodexSessionFileRecord]
  ) -> [TokenUsageEvent] {
    var seenUsageBySessionID: [String: Set<UsageIdentity>] = [:]
    var sessionEvents: [TokenUsageEvent] = []
    var legacyEvents: [TokenUsageEvent] = []

    for record in records {
      guard let sessionID = record.sessionID else {
        legacyEvents.append(contentsOf: record.events)
        continue
      }
      for event in record.events {
        let identity = UsageIdentity(event: event)
        if seenUsageBySessionID[sessionID, default: []].insert(identity).inserted {
          sessionEvents.append(event)
        }
      }
    }
    return (legacyEvents + sessionEvents).sorted { $0.timestamp < $1.timestamp }
  }

  static func defaultCodexHome() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
      return URL(filePath: override, directoryHint: .isDirectory)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex", directoryHint: .isDirectory)
  }

  private func sessionFiles(
    under root: URL
  ) throws -> [CodexSessionFileDescriptor] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .fileSizeKey,
          .contentModificationDateKey,
          .fileResourceIdentifierKey,
        ],
        options: [.skipsHiddenFiles],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else {
      throw CocoaError(.fileReadUnknown)
    }

    var descriptors: [CodexSessionFileDescriptor] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      descriptors.append(
        CodexSessionFileDescriptor(url: url, fingerprint: try fingerprint(for: url))
      )
    }
    if let enumerationError {
      throw enumerationError
    }
    return descriptors
  }
}

private struct UsageIdentity: Hashable {
  let eventIndex: Int
  let day: Date
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let turnID: String?
  let model: String?

  init(event: TokenUsageEvent) {
    eventIndex = event.eventIndex ?? 0
    day = Calendar.current.startOfDay(for: event.timestamp)
    inputTokens = event.inputTokens
    cachedInputTokens = event.cachedInputTokens
    outputTokens = event.outputTokens
    turnID = event.turnID
    model = event.model
  }
}
```

- [ ] **Step 4: Run scanner and parser regression tests**

Run:

```bash
swift test --filter CodexSessionScannerTests
swift test --filter CodexSessionParserTests
```

Expected: both pass, including active/archived duplicate-session coverage.

- [ ] **Step 5: Commit the scanner split**

```bash
git add Sources/CodexRadar/Services/CodexSessionScanner.swift Tests/CodexRadarTests/CodexSessionScannerTests.swift
git commit -m "refactor: split codex session scanning"
```

---

### Task 3: Persist versioned snapshot and manifest caches

**Files:**

- Create: `Sources/CodexRadar/Services/TokenUsageCacheStore.swift`
- Create: `Tests/CodexRadarTests/TokenUsageCacheStoreTests.swift`

**Interfaces:**

- Consumes: `TokenUsageSnapshot`, `TokenUsageManifest`
- Produces: `loadSnapshot()`, `loadManifest()`, `saveSnapshot(_:)`, `saveManifest(_:)`

- [ ] **Step 1: Write failing cache-store tests**

Create `Tests/CodexRadarTests/TokenUsageCacheStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexRadar

struct TokenUsageCacheStoreTests {
  @Test
  func roundTripsCompatibleSnapshotAndManifest() throws {
    let context = try CacheTestContext()
    defer { context.remove() }
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [],
      at: Date(timeIntervalSince1970: 1_700_000_000),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let manifest = TokenUsageManifest(files: [])

    try context.store.saveManifest(manifest)
    try context.store.saveSnapshot(snapshot)

    #expect(try context.store.loadManifest() == manifest)
    #expect(try context.store.loadSnapshot() == snapshot)
  }

  @Test
  func treatsCorruptFilesAsCacheMisses() throws {
    let context = try CacheTestContext()
    defer { context.remove() }
    try Data("broken".utf8).write(to: context.store.snapshotURL)
    try Data("broken".utf8).write(to: context.store.manifestURL)

    #expect(try context.store.loadSnapshot() == nil)
    #expect(try context.store.loadManifest() == nil)
  }

  @Test
  func treatsIncompatibleVersionsAsCacheMisses() throws {
    let context = try CacheTestContext()
    defer { context.remove() }
    let compatible = TokenUsageSnapshotBuilder.make(
      events: [],
      at: Date(timeIntervalSince1970: 1_700_000_000),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let incompatible = TokenUsageSnapshot(
      schemaVersion: 999,
      parserVersion: compatible.parserVersion,
      generatedAt: compatible.generatedAt,
      timeZoneIdentifier: compatible.timeZoneIdentifier,
      hasUsageData: compatible.hasUsageData,
      dailyBuckets: compatible.dailyBuckets,
      monthlyBuckets: compatible.monthlyBuckets,
      yearlyBuckets: compatible.yearlyBuckets
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(incompatible).write(
      to: context.store.snapshotURL,
      options: .atomic
    )

    #expect(try context.store.loadSnapshot() == nil)
  }
}

private struct CacheTestContext {
  let directory: URL
  let store: TokenUsageCacheStore

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    store = TokenUsageCacheStore(directoryURL: directory)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
```

- [ ] **Step 2: Run the cache tests and verify they fail**

Run:

```bash
swift test --filter TokenUsageCacheStoreTests
```

Expected: compilation fails because `TokenUsageCacheStore` does not exist.

- [ ] **Step 3: Implement atomic property-list storage**

Create `Sources/CodexRadar/Services/TokenUsageCacheStore.swift`:

```swift
import Foundation

struct TokenUsageCacheStore: Sendable {
  let directoryURL: URL

  var snapshotURL: URL {
    directoryURL.appending(path: "token-usage-snapshot-v1.plist")
  }

  var manifestURL: URL {
    directoryURL.appending(path: "token-usage-manifest-v1.plist")
  }

  init(directoryURL: URL = Self.defaultDirectory()) {
    self.directoryURL = directoryURL
  }

  func loadSnapshot() throws -> TokenUsageSnapshot? {
    guard let snapshot: TokenUsageSnapshot = try decodeIfPresent(from: snapshotURL) else {
      return nil
    }
    return snapshot.isCompatible ? snapshot : nil
  }

  func loadManifest() throws -> TokenUsageManifest? {
    guard let manifest: TokenUsageManifest = try decodeIfPresent(from: manifestURL) else {
      return nil
    }
    return manifest.isCompatible ? manifest : nil
  }

  func saveSnapshot(_ snapshot: TokenUsageSnapshot) throws {
    try encode(snapshot, to: snapshotURL)
  }

  func saveManifest(_ manifest: TokenUsageManifest) throws {
    try encode(manifest, to: manifestURL)
  }

  static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appending(
      path: "com.terence.codex-radar/token-usage",
      directoryHint: .isDirectory
    )
  }

  private func decodeIfPresent<Value: Decodable>(
    from url: URL
  ) throws -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try PropertyListDecoder().decode(Value.self, from: Data(contentsOf: url))
    } catch {
      return nil
    }
  }

  private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(value).write(to: url, options: .atomic)
  }
}
```

- [ ] **Step 4: Run focused cache tests**

Run:

```bash
swift test --filter TokenUsageCacheStoreTests
```

Expected: all cache-store tests pass.

- [ ] **Step 5: Commit the cache store**

```bash
git add Sources/CodexRadar/Services/TokenUsageCacheStore.swift Tests/CodexRadarTests/TokenUsageCacheStoreTests.swift
git commit -m "feat: persist token usage caches"
```

---

### Task 4: Implement incremental Repository refresh

**Files:**

- Create: `Sources/CodexRadar/Services/TokenUsageRepository.swift`
- Create: `Tests/CodexRadarTests/TokenUsageRepositoryTests.swift`

**Interfaces:**

- Consumes: Scanner file descriptors, parser, cache store, snapshot builder
- Produces: `TokenUsageRepository.cachedSnapshot(timeZone:)`
- Produces: `TokenUsageRepository.refresh(timeZone:)`
- Produces: `TokenUsageRepositoryResult` and `TokenUsageRepositoryIssue`

- [ ] **Step 1: Write failing incremental-refresh tests**

Create `Tests/CodexRadarTests/TokenUsageRepositoryTests.swift` with real temporary JSONL files and a parse counter:

```swift
import Foundation
import Testing

@testable import CodexRadar

struct TokenUsageRepositoryTests {
  @Test
  func unchangedRefreshParsesEachFileOnlyOnce() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)

    let first = await context.repository.refresh(timeZone: context.timeZone)
    let second = await context.repository.refresh(timeZone: context.timeZone)

    #expect(first.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(second.snapshot == first.snapshot)
    #expect(context.parseCount.value == 1)
  }

  @Test
  func changedFileIsReparsedAndReplacesItsOldContribution() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)
    _ = await context.repository.refresh(timeZone: context.timeZone)

    try context.writeSession(input: 250, output: 25, modifiedAt: 1_700_000_100)
    let refreshed = await context.repository.refresh(timeZone: context.timeZone)

    #expect(refreshed.snapshot?.metrics(for: .day).totalTokens == 275)
    #expect(context.parseCount.value == 2)
  }

  @Test
  func sourceFailureKeepsTheLastCachedSnapshot() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)
    let first = await context.repository.refresh(timeZone: context.timeZone)
    context.discoveryError.value = CocoaError(.fileReadNoPermission)

    let failed = await context.repository.refresh(timeZone: context.timeZone)

    #expect(failed.snapshot == first.snapshot)
    #expect(failed.issues == [.sourceUnavailable])
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }

  func update(_ body: (inout Value) -> Void) {
    lock.withLock { body(&storage) }
  }

  func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.withLock { body(&storage) }
  }
}

private struct RepositoryTestContext {
  let root: URL
  let file: URL
  let timeZone = TimeZone(secondsFromGMT: 0)!
  let parseCount: LockedBox<Int>
  let discoveryError: LockedBox<Error?>
  let repository: TokenUsageRepository

  init() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = rootURL.appending(path: "sessions/2026/07/28/session.jsonl")
    let parseCounter = LockedBox(0)
    let errorBox = LockedBox<Error?>(nil)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let scanner = CodexSessionScanner()
    root = rootURL
    file = fileURL
    parseCount = parseCounter
    discoveryError = errorBox
    repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(
        directoryURL: rootURL.appending(path: "cache", directoryHint: .isDirectory)
      ),
      discoverFiles: {
        if let error = errorBox.value { throw error }
        return try scanner.discoverFiles(codexHome: rootURL)
      },
      fingerprintFile: { try scanner.fingerprint(for: $0) },
      parseFile: {
        parseCounter.update { $0 += 1 }
        return try scanner.parseFile(at: $0)
      },
      now: { ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")! }
    )
  }

  func writeSession(
    input: Int,
    output: Int,
    modifiedAt: TimeInterval = 1_700_000_000
  ) throws {
    let contents = """
      {"timestamp":"2026-07-28T00:00:00Z","type":"session_meta","payload":{"session_id":"session-1"}}
      {"timestamp":"2026-07-28T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"output_tokens":\(output)}}}}
      """
    try Data(contents.utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: modifiedAt)],
      ofItemAtPath: file.path
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
```

- [ ] **Step 2: Run Repository tests and verify they fail**

Run:

```bash
swift test --filter TokenUsageRepositoryTests
```

Expected: compilation fails because Repository result and issue types do not exist.

- [ ] **Step 3: Implement Repository issue and result types**

Create `Sources/CodexRadar/Services/TokenUsageRepository.swift` with these declarations:

```swift
import Foundation

enum TokenUsageRepositoryIssue: Equatable, Sendable {
  case sourceUnavailable
  case skippedFiles(Int)
  case cacheWriteFailed
}

struct TokenUsageRepositoryResult: Equatable, Sendable {
  let snapshot: TokenUsageSnapshot?
  let issues: [TokenUsageRepositoryIssue]
}
```

- [ ] **Step 4: Implement cache-first and incremental refresh**

Add the actor below to the same file:

```swift
actor TokenUsageRepository {
  typealias DiscoverFiles = @Sendable () throws -> [CodexSessionFileDescriptor]
  typealias FingerprintFile =
    @Sendable (URL) throws -> CodexSessionFileFingerprint
  typealias ParseFile = @Sendable (URL) throws -> ParsedCodexSessionFile
  typealias Now = @Sendable () -> Date

  private let cacheStore: TokenUsageCacheStore
  private let discoverFiles: DiscoverFiles
  private let fingerprintFile: FingerprintFile
  private let parseFile: ParseFile
  private let now: Now

  init(
    codexHome: URL = CodexSessionScanner.defaultCodexHome(),
    cacheStore: TokenUsageCacheStore = TokenUsageCacheStore(),
    scanner: CodexSessionScanner = CodexSessionScanner(),
    now: @escaping Now = Date.init
  ) {
    self.cacheStore = cacheStore
    discoverFiles = { try scanner.discoverFiles(codexHome: codexHome) }
    fingerprintFile = { try scanner.fingerprint(for: $0) }
    parseFile = { try scanner.parseFile(at: $0) }
    self.now = now
  }

  init(
    cacheStore: TokenUsageCacheStore,
    discoverFiles: @escaping DiscoverFiles,
    fingerprintFile: @escaping FingerprintFile,
    parseFile: @escaping ParseFile,
    now: @escaping Now
  ) {
    self.cacheStore = cacheStore
    self.discoverFiles = discoverFiles
    self.fingerprintFile = fingerprintFile
    self.parseFile = parseFile
    self.now = now
  }

  func cachedSnapshot(timeZone: TimeZone) -> TokenUsageSnapshot? {
    guard
      let snapshot = try? cacheStore.loadSnapshot(),
      snapshot.timeZoneIdentifier == timeZone.identifier
    else {
      return nil
    }
    return snapshot
  }

  func refresh(timeZone: TimeZone) -> TokenUsageRepositoryResult {
    let previousManifest: TokenUsageManifest?
    do {
      previousManifest = try cacheStore.loadManifest()
    } catch {
      previousManifest = nil
    }
    let fallbackSnapshot = fallbackSnapshot(
      manifest: previousManifest,
      timeZone: timeZone
    )

    let descriptors: [CodexSessionFileDescriptor]
    do {
      descriptors = try discoverFiles()
    } catch {
      return TokenUsageRepositoryResult(
        snapshot: fallbackSnapshot,
        issues: [.sourceUnavailable]
      )
    }

    var previousByIdentity: [String: CodexSessionFileRecord] = [:]
    for record in previousManifest?.files ?? [] {
      previousByIdentity[record.fingerprint.cacheIdentity] = record
    }
    var records: [CodexSessionFileRecord] = []
    var skippedFileCount = 0

    for descriptor in descriptors {
      let identity = descriptor.fingerprint.cacheIdentity
      let previous = previousByIdentity.removeValue(forKey: identity)
      if let previous,
        previous.fingerprint.hasSameContent(as: descriptor.fingerprint)
      {
        records.append(
          CodexSessionFileRecord(
            fingerprint: descriptor.fingerprint,
            sessionID: previous.sessionID,
            events: previous.events
          )
        )
        continue
      }

      do {
        records.append(try stableRecord(for: descriptor))
      } catch {
        skippedFileCount += 1
        if let previous {
          records.append(previous)
        }
      }
    }

    records.sort { $0.fingerprint.path < $1.fingerprint.path }
    let events = CodexSessionScanner.deduplicatedEvents(from: records)
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: events,
      at: now(),
      timeZone: timeZone
    )
    let manifest = TokenUsageManifest(files: records)
    var issues: [TokenUsageRepositoryIssue] = []
    if skippedFileCount > 0 {
      issues.append(.skippedFiles(skippedFileCount))
    }

    do {
      try cacheStore.saveManifest(manifest)
      try cacheStore.saveSnapshot(snapshot)
    } catch {
      issues.append(.cacheWriteFailed)
    }
    return TokenUsageRepositoryResult(snapshot: snapshot, issues: issues)
  }

  private func stableRecord(
    for descriptor: CodexSessionFileDescriptor
  ) throws -> CodexSessionFileRecord {
    var expectedFingerprint = descriptor.fingerprint
    for _ in 0..<2 {
      let parsed = try parseFile(descriptor.url)
      let finalFingerprint = try fingerprintFile(descriptor.url)
      if expectedFingerprint.hasSameContent(as: finalFingerprint) {
        return CodexSessionFileRecord(
          fingerprint: finalFingerprint,
          sessionID: parsed.sessionID,
          events: parsed.events
        )
      }
      expectedFingerprint = finalFingerprint
    }
    throw CocoaError(.fileReadUnknown)
  }

  private func fallbackSnapshot(
    manifest: TokenUsageManifest?,
    timeZone: TimeZone
  ) -> TokenUsageSnapshot? {
    if let cached = cachedSnapshot(timeZone: timeZone) {
      return cached
    }
    guard let manifest else { return nil }
    return TokenUsageSnapshotBuilder.make(
      events: CodexSessionScanner.deduplicatedEvents(from: manifest.files),
      at: now(),
      timeZone: timeZone
    )
  }
}
```

- [ ] **Step 5: Add move, delete, parse-failure, and unstable-file tests**

Extend `TokenUsageRepositoryTests` with these focused cases:

```swift
@Test
func deletingTheOnlyFileProducesAnEmptySnapshot() async throws {
  let context = try RepositoryTestContext()
  defer { context.remove() }
  try context.writeSession(input: 100, output: 10)
  _ = await context.repository.refresh(timeZone: context.timeZone)
  try FileManager.default.removeItem(at: context.file)

  let refreshed = await context.repository.refresh(timeZone: context.timeZone)

  #expect(refreshed.snapshot?.hasUsageData == false)
}

@Test
func cachedSnapshotIsRejectedForAnotherTimeZone() async throws {
  let context = try RepositoryTestContext()
  defer { context.remove() }
  try context.writeSession(input: 100, output: 10)
  _ = await context.repository.refresh(timeZone: context.timeZone)

  let other = await context.repository.cachedSnapshot(
    timeZone: TimeZone(identifier: "Asia/Shanghai")!
  )

  #expect(other == nil)
}

@Test
func movedFileWithStableResourceIdentifierReusesParsedEvents() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let active = descriptor(
    path: "/tmp/sessions/session.jsonl",
    resource: "resource-1",
    size: 100,
    modifiedAt: modifiedAt
  )
  let archived = descriptor(
    path: "/tmp/archived_sessions/session.jsonl",
    resource: "resource-1",
    size: 100,
    modifiedAt: modifiedAt
  )
  let current = LockedBox(active)
  let parseCount = LockedBox(0)
  let parsed = ParsedCodexSessionFile(
    sessionID: "session-1",
    events: [
      TokenUsageEvent(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        inputTokens: 100,
        cachedInputTokens: 90,
        outputTokens: 10
      )
    ]
  )
  let repository = TokenUsageRepository(
    cacheStore: TokenUsageCacheStore(directoryURL: directory),
    discoverFiles: { [current.value] },
    fingerprintFile: { _ in current.value.fingerprint },
    parseFile: { _ in
      parseCount.update { $0 += 1 }
      return parsed
    },
    now: { Date(timeIntervalSince1970: 1_700_000_100) }
  )

  _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)
  current.value = archived
  _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

  #expect(parseCount.value == 1)
}

@Test
func fileChangingDuringBothParseAttemptsIsNotCached() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  let initial = descriptor(
    path: "/tmp/sessions/session.jsonl",
    resource: "resource-1",
    size: 100,
    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
  let fingerprints = LockedBox([
    CodexSessionFileFingerprint(
      path: initial.fingerprint.path,
      resourceIdentifier: "resource-1",
      size: 110,
      modificationDate: Date(timeIntervalSince1970: 1_700_000_010)
    ),
    CodexSessionFileFingerprint(
      path: initial.fingerprint.path,
      resourceIdentifier: "resource-1",
      size: 120,
      modificationDate: Date(timeIntervalSince1970: 1_700_000_020)
    ),
  ])
  let parseCount = LockedBox(0)
  let repository = TokenUsageRepository(
    cacheStore: TokenUsageCacheStore(directoryURL: directory),
    discoverFiles: { [initial] },
    fingerprintFile: { _ in
      fingerprints.withValue { $0.removeFirst() }
    },
    parseFile: { _ in
      parseCount.update { $0 += 1 }
      return ParsedCodexSessionFile(sessionID: "session-1", events: [])
    },
    now: { Date(timeIntervalSince1970: 1_700_000_100) }
  )

  let result = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

  #expect(parseCount.value == 2)
  #expect(result.issues == [.skippedFiles(1)])
  #expect(result.snapshot?.hasUsageData == false)
}

private func descriptor(
  path: String,
  resource: String,
  size: Int64,
  modifiedAt: Date
) -> CodexSessionFileDescriptor {
  CodexSessionFileDescriptor(
    url: URL(filePath: path),
    fingerprint: CodexSessionFileFingerprint(
      path: path,
      resourceIdentifier: resource,
      size: size,
      modificationDate: modifiedAt
    )
  )
}
```

Also add:

```swift
@Test
func modifiedFileParseFailureKeepsOldRecordAndRetriesLater() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  let original = descriptor(
    path: "/tmp/sessions/session.jsonl",
    resource: "resource-1",
    size: 100,
    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
  )
  let modified = descriptor(
    path: original.fingerprint.path,
    resource: "resource-1",
    size: 120,
    modifiedAt: Date(timeIntervalSince1970: 1_700_000_020)
  )
  let current = LockedBox(original)
  let shouldFail = LockedBox(false)
  let parseCount = LockedBox(0)
  let repository = TokenUsageRepository(
    cacheStore: TokenUsageCacheStore(directoryURL: directory),
    discoverFiles: { [current.value] },
    fingerprintFile: { _ in current.value.fingerprint },
    parseFile: { _ in
      parseCount.update { $0 += 1 }
      if shouldFail.value {
        throw CocoaError(.fileReadCorruptFile)
      }
      return ParsedCodexSessionFile(
        sessionID: "session-1",
        events: [
          TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            inputTokens: 100,
            cachedInputTokens: 90,
            outputTokens: 10
          )
        ]
      )
    },
    now: { Date(timeIntervalSince1970: 1_700_000_100) }
  )

  _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)
  current.value = modified
  shouldFail.value = true
  let firstFailure = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)
  let secondFailure = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

  #expect(firstFailure.snapshot?.metrics(for: .day).totalTokens == 110)
  #expect(secondFailure.snapshot?.metrics(for: .day).totalTokens == 110)
  #expect(firstFailure.issues == [.skippedFiles(1)])
  #expect(secondFailure.issues == [.skippedFiles(1)])
  #expect(parseCount.value == 3)
}

@Test
func cacheWriteFailureKeepsTheInMemorySnapshot() async throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let blockedDirectory = root.appending(path: "not-a-directory")
  try Data("file".utf8).write(to: blockedDirectory)
  let repository = TokenUsageRepository(
    cacheStore: TokenUsageCacheStore(directoryURL: blockedDirectory),
    discoverFiles: { [] },
    fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
    parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
    now: { Date(timeIntervalSince1970: 1_700_000_100) }
  )

  let result = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

  #expect(result.snapshot != nil)
  #expect(result.issues == [.cacheWriteFailed])
}
```

- [ ] **Step 6: Run Repository and cache regression tests**

Run:

```bash
swift test --filter TokenUsageRepositoryTests
swift test --filter TokenUsageCacheStoreTests
swift test --filter CodexSessionScannerTests
```

Expected: all pass; the unchanged-refresh test reports one parser call across two refreshes.

- [ ] **Step 7: Commit the Repository**

```bash
git add Sources/CodexRadar/Services/TokenUsageRepository.swift Tests/CodexRadarTests/TokenUsageRepositoryTests.swift
git commit -m "feat: refresh token usage incrementally"
```

---

### Task 5: Integrate snapshots into DashboardStore and menu bar

**Files:**

- Modify: `Sources/CodexRadar/Stores/DashboardStore.swift`
- Modify: `Sources/CodexRadar/Views/ContentView.swift`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Modify: `Sources/CodexRadar/Views/TokenUsageView.swift`
- Modify: `Sources/CodexRadar/Models/TokenUsage.swift`
- Create: `Tests/CodexRadarTests/DashboardStoreTokenUsageTests.swift`
- Modify: `Tests/CodexRadarTests/DashboardStoreForecastTests.swift`
- Modify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift`
- Modify: `Tests/CodexRadarTests/MenuBarControllerTests.swift`

**Interfaces:**

- Consumes: `TokenUsageRepository.cachedSnapshot(timeZone:)` and `refresh(timeZone:)`
- Produces: `DashboardStore.tokenUsageSnapshot`
- Produces: `DashboardStore.refreshTokenUsage(timeZone:)`
- Preserves: forecast polling and notification behavior

- [ ] **Step 1: Write failing DashboardStore Token tests**

Create `Tests/CodexRadarTests/DashboardStoreTokenUsageTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexRadar

struct DashboardStoreTokenUsageTests {
  @MainActor
  @Test
  func publishesCachedSnapshotBeforeFreshSnapshot() async {
    let cached = snapshot(total: 10)
    let fresh = snapshot(total: 20)
    let repository = ControlledTokenUsageSource(
      cached: cached,
      fresh: fresh,
      shouldSuspend: true
    )
    let store = makeTokenStore(repository: repository)

    let refresh = Task { await store.refresh() }
    await repository.waitForRefresh()

    #expect(store.tokenUsageSnapshot == cached)

    await repository.completeRefresh()
    await refresh.value
    #expect(store.tokenUsageSnapshot == fresh)
  }

  @MainActor
  @Test
  func sourceFailureKeepsCachedSnapshotAndPublishesIssue() async {
    let cached = snapshot(total: 10)
    let repository = ControlledTokenUsageSource(
      cached: cached,
      fresh: nil,
      issues: [.sourceUnavailable],
      shouldSuspend: false
    )
    let store = makeTokenStore(repository: repository)

    await store.refresh()

    #expect(store.tokenUsageSnapshot == cached)
    #expect(store.issues.count == 1)
  }

  @MainActor
  @Test
  func olderTimeZoneRefreshCannotOverwriteNewerResult() async {
    let source = OutOfOrderTokenUsageSource()
    let store = DashboardStore(
      loadCachedTokenUsage: { _ in nil },
      refreshTokenUsageSource: { _ in await source.refresh() },
      formatTokenUsageIssue: { _ in "Token usage issue" },
      fetchForecast: { _ in .notModified },
      prepareNotifications: {},
      observeForecast: { _ in },
      formatForecastIssue: { $0 ?? "" },
      pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
      sleep: { _ in },
      observesWakeEvents: false
    )
    let first = Task {
      await store.refreshTokenUsage(timeZone: TimeZone(secondsFromGMT: 0)!)
    }
    await source.waitForCallCount(1)
    let second = Task {
      await store.refreshTokenUsage(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    }
    await source.waitForCallCount(2)

    await source.complete(call: 1, snapshot: snapshot(total: 20))
    await second.value
    await source.complete(call: 0, snapshot: snapshot(total: 10))
    await first.value

    #expect(store.tokenUsageSnapshot == snapshot(total: 20))
  }
}

private actor ControlledTokenUsageSource {
  let cached: TokenUsageSnapshot?
  let fresh: TokenUsageSnapshot?
  let issues: [TokenUsageRepositoryIssue]
  let shouldSuspend: Bool
  private var refreshStarted = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(
    cached: TokenUsageSnapshot?,
    fresh: TokenUsageSnapshot?,
    issues: [TokenUsageRepositoryIssue] = [],
    shouldSuspend: Bool
  ) {
    self.cached = cached
    self.fresh = fresh
    self.issues = issues
    self.shouldSuspend = shouldSuspend
  }

  func cachedSnapshot() -> TokenUsageSnapshot? {
    cached
  }

  func refresh() async -> TokenUsageRepositoryResult {
    refreshStarted = true
    if shouldSuspend {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }
    return TokenUsageRepositoryResult(snapshot: fresh, issues: issues)
  }

  func waitForRefresh() async {
    while !refreshStarted {
      await Task.yield()
    }
  }

  func completeRefresh() {
    continuation?.resume()
    continuation = nil
  }
}

private actor OutOfOrderTokenUsageSource {
  private var continuations: [CheckedContinuation<TokenUsageRepositoryResult, Never>?] = []

  func refresh() async -> TokenUsageRepositoryResult {
    let index = continuations.count
    continuations.append(nil)
    return await withCheckedContinuation { continuation in
      continuations[index] = continuation
    }
  }

  func waitForCallCount(_ count: Int) async {
    while continuations.count < count {
      await Task.yield()
    }
  }

  func complete(call index: Int, snapshot: TokenUsageSnapshot) {
    continuations[index]?.resume(
      returning: TokenUsageRepositoryResult(snapshot: snapshot, issues: [])
    )
    continuations[index] = nil
  }
}

@MainActor
private func makeTokenStore(
  repository: ControlledTokenUsageSource
) -> DashboardStore {
  DashboardStore(
    loadCachedTokenUsage: { _ in
      await repository.cachedSnapshot()
    },
    refreshTokenUsageSource: { _ in
      await repository.refresh()
    },
    formatTokenUsageIssue: { issue in
      "Token usage issue: \(String(describing: issue))"
    },
    fetchForecast: { _ in .notModified },
    prepareNotifications: {},
    observeForecast: { _ in },
    formatForecastIssue: { $0 ?? "" },
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: { _ in },
    observesWakeEvents: false
  )
}

private func snapshot(total: Int) -> TokenUsageSnapshot {
  TokenUsageSnapshotBuilder.make(
    events: [
      TokenUsageEvent(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        inputTokens: total,
        cachedInputTokens: 0,
        outputTokens: 0
      )
    ],
    at: Date(timeIntervalSince1970: 1_700_000_100),
    timeZone: TimeZone(secondsFromGMT: 0)!
  )
}
```

- [ ] **Step 2: Run the store tests and verify they fail**

Run:

```bash
swift test --filter DashboardStoreTokenUsageTests
```

Expected: compilation fails because `DashboardStore` still publishes `tokenEvents` and accepts `scanSessions`.

- [ ] **Step 3: Replace the scanner dependency with Repository closures**

In `DashboardStore`, replace:

```swift
@Published private(set) var tokenEvents: [TokenUsageEvent] = []
private let scanSessions: @Sendable () throws -> [TokenUsageEvent]
```

with:

```swift
@Published private(set) var tokenUsageSnapshot: TokenUsageSnapshot?

private let loadCachedTokenUsage:
  @Sendable (TimeZone) async -> TokenUsageSnapshot?
private let refreshTokenUsageSource:
  @Sendable (TimeZone) async -> TokenUsageRepositoryResult
private let formatTokenUsageIssue:
  @MainActor @Sendable (TokenUsageRepositoryIssue) -> String
private var tokenUsageIssues: [String] = []
private var tokenUsageGeneration: UInt64 = 0
```

The live initializer creates one Repository and captures it:

```swift
let tokenUsageRepository = TokenUsageRepository()
loadCachedTokenUsage = {
  await tokenUsageRepository.cachedSnapshot(timeZone: $0)
}
refreshTokenUsageSource = {
  await tokenUsageRepository.refresh(timeZone: $0)
}
formatTokenUsageIssue = { issue in
  let message =
    switch issue {
    case .sourceUnavailable:
      AppLocalization.string("Token usage source is temporarily unavailable.")
    case .skippedFiles(let count):
      String(
        format: AppLocalization.string("Token usage skipped %lld log files."),
        count
      )
    case .cacheWriteFailed:
      AppLocalization.string("Token usage cache could not be saved.")
    }
  return String(
    format: AppLocalization.string("Token usage: %@"),
    message
  )
}
```

Replace the beginning of the test initializer with this signature and assignments:

```swift
init(
  loadCachedTokenUsage: @escaping @Sendable (TimeZone) async -> TokenUsageSnapshot? = {
    _ in nil
  },
  refreshTokenUsageSource:
    @escaping @Sendable (TimeZone) async -> TokenUsageRepositoryResult = {
      _ in TokenUsageRepositoryResult(snapshot: nil, issues: [])
    },
  formatTokenUsageIssue:
    @escaping @MainActor @Sendable (TokenUsageRepositoryIssue) -> String = {
      "Token usage issue: \(String(describing: $0))"
    },
  fetchForecast: @escaping @Sendable (String?) async throws -> ResetForecastFetchResult,
  prepareNotifications: @escaping @MainActor @Sendable () async -> Void,
  observeForecast: @escaping @MainActor @Sendable (ResetForecast) async -> Void,
  formatForecastIssue: @escaping @MainActor @Sendable (String?) -> String,
  pollingSchedule: ResetPollingSchedule,
  sleep: @escaping @Sendable (Duration) async throws -> Void,
  observesWakeEvents: Bool
) {
  self.loadCachedTokenUsage = loadCachedTokenUsage
  self.refreshTokenUsageSource = refreshTokenUsageSource
  self.formatTokenUsageIssue = formatTokenUsageIssue
  self.fetchForecast = fetchForecast
  self.prepareNotifications = prepareNotifications
  self.observeForecast = observeForecast
  self.formatForecastIssue = formatForecastIssue
  self.pollingSchedule = pollingSchedule
  self.sleep = sleep
  self.observesWakeEvents = observesWakeEvents
}
```

Delete `scanSessions: { [] },` from the existing test helpers in
`DashboardStoreForecastTests`, `MenuActionLayoutTests`, and
`MenuBarControllerTests`; the new defaults supply an empty Token result.

- [ ] **Step 4: Publish cached data before starting source refresh**

Replace the detached scanner portion of `refresh(generation:)` with:

```swift
let timeZone = TimeZone.autoupdatingCurrent
tokenUsageGeneration &+= 1
let tokenGeneration = tokenUsageGeneration

if tokenUsageSnapshot == nil,
  let cached = await loadCachedTokenUsage(timeZone),
  generation == forecastGeneration,
  tokenGeneration == tokenUsageGeneration,
  !Task.isCancelled
{
  tokenUsageSnapshot = cached
}

async let usageResult = refreshTokenUsageSource(timeZone)
await requestForecastRefresh(trigger: .manual, generation: generation)
let result = await usageResult
guard generation == forecastGeneration,
  tokenGeneration == tokenUsageGeneration,
  !Task.isCancelled
else {
  return
}
applyTokenUsage(result)
```

Add:

```swift
func refreshTokenUsage(timeZone: TimeZone) async {
  tokenUsageGeneration &+= 1
  let generation = tokenUsageGeneration
  let result = await refreshTokenUsageSource(timeZone)
  guard generation == tokenUsageGeneration, !Task.isCancelled else { return }
  applyTokenUsage(result)
}

private func applyTokenUsage(_ result: TokenUsageRepositoryResult) {
  if let snapshot = result.snapshot {
    tokenUsageSnapshot = snapshot
  }
  tokenUsageIssues = result.issues.map(formatTokenUsageIssue)
  rebuildIssues()
}

private func rebuildIssues() {
  issues = forecastIssue.map { [$0] } ?? []
  issues.append(contentsOf: tokenUsageIssues)
}

private func removeForecastIssue() {
  forecastIssue = nil
  rebuildIssues()
}

private func setForecastIssue(error: Error) {
  let message = error as? ResetForecastServiceError == .notInitialized
    ? AppLocalization.string("Reset monitoring is starting up.")
    : AppLocalization.string("Reset monitoring is temporarily unavailable.")
  forecastIssue = formatForecastIssue(message)
  rebuildIssues()
}
```

Use these replacements for the old forecast issue helpers. Increment
`tokenUsageGeneration` in `stopMonitoring()` so a late refresh cannot publish after shutdown.
Also replace `issues = forecastIssue.map { [$0] } ?? []` at the start of
`refresh(generation:)` with `rebuildIssues()` so a forecast refresh does not erase a
still-active Token warning.

- [ ] **Step 5: Switch ContentView and menu metrics to snapshot data**

In `ContentView`:

```swift
TokenUsageView(snapshot: store.tokenUsageSnapshot)
```

Change the overlay condition to:

```swift
if store.isRefreshing && store.tokenUsageSnapshot == nil
```

Extend the existing time-zone change handler:

```swift
.onChange(of: timeZone.identifier) {
  historyStore.refresh(timeZone: timeZone)
  Task {
    await store.refreshTokenUsage(timeZone: timeZone)
  }
}
```

In `MenuBarView`, replace the two computed totals:

```swift
private var todayTokens: Int {
  store.tokenUsageSnapshot?.metrics(for: .day).totalTokens ?? 0
}

private var monthTokens: Int {
  store.tokenUsageSnapshot?.metrics(for: .month).totalTokens ?? 0
}
```

Update the top of `TokenUsageView` to:

```swift
struct TokenUsageView: View {
  let snapshot: TokenUsageSnapshot?
  @State private var period: TokenUsagePeriod = .day
  @Environment(\.locale) private var locale

  private var metrics: TokenUsageMetrics {
    snapshot?.metrics(for: period) ?? .zero
  }

  private var buckets: [TokenUsageChartBucket] {
    snapshot?.buckets(for: period) ?? []
  }
```

Replace the metric row with:

```swift
HStack(spacing: 12) {
  MetricTile(
    title: "Total",
    value: metrics.totalTokens,
    tint: .accentColor,
    locale: locale
  )
  MetricTile(
    title: "Input",
    value: metrics.inputTokens,
    tint: .blue,
    locale: locale
  )
  MetricTile(
    title: "Output",
    value: metrics.outputTokens,
    tint: .purple,
    locale: locale
  )
}
```

Change the empty-state condition to `snapshot?.hasUsageData != true`, change
`Chart(visibleBuckets)` to `Chart(buckets)`, and delete the detail-row `VStack` plus
the entire private `UsageRow` type. This intermediate view compiles with snapshot
data and already removes Cached and the redundant rows; Task 6 adds hover behavior.

- [ ] **Step 6: Remove the obsolete event aggregator**

After all production call sites use snapshots, delete `TokenUsageBucket` and
`TokenUsageAggregator` from `Sources/CodexRadar/Models/TokenUsage.swift`.
Move the old aggregation assertions in `CodexSessionParserTests` to
`TokenUsageSnapshotTests`, then confirm no production code references the old symbols:

```bash
rg -n "TokenUsageAggregator|TokenUsageBucket|tokenEvents|scanSessions" Sources Tests
```

Expected: no production references; only deliberate migration comments, if any.

- [ ] **Step 7: Run store, menu, parser, and snapshot tests**

Run:

```bash
swift test --filter DashboardStoreTokenUsageTests
swift test --filter DashboardStoreForecastTests
swift test --filter MenuActionLayoutTests
swift test --filter MenuBarControllerTests
swift test --filter TokenUsageSnapshotTests
swift test --filter CodexSessionParserTests
```

Expected: all pass; cached data is observable before the controlled fresh refresh completes.

- [ ] **Step 8: Commit Store integration**

```bash
git add Sources/CodexRadar/Stores/DashboardStore.swift Sources/CodexRadar/Views/ContentView.swift Sources/CodexRadar/Views/MenuBarView.swift Sources/CodexRadar/Views/TokenUsageView.swift Sources/CodexRadar/Models/TokenUsage.swift Tests/CodexRadarTests/DashboardStoreTokenUsageTests.swift Tests/CodexRadarTests/DashboardStoreForecastTests.swift Tests/CodexRadarTests/MenuActionLayoutTests.swift Tests/CodexRadarTests/MenuBarControllerTests.swift Tests/CodexRadarTests/CodexSessionParserTests.swift Tests/CodexRadarTests/TokenUsageSnapshotTests.swift
git commit -m "feat: publish cached token usage snapshots"
```

---

### Task 6: Replace detail rows with hover interaction

**Files:**

- Create: `Sources/CodexRadar/Models/TokenUsagePresentation.swift`
- Create: `Tests/CodexRadarTests/TokenUsagePresentationTests.swift`
- Modify: `Sources/CodexRadar/Views/TokenUsageView.swift`

**Interfaces:**

- Consumes: `TokenUsageSnapshot`, `TokenUsagePeriod`, pointer x-coordinate as `Date`
- Produces: `TokenUsagePresentation.metrics`, `buckets`, and `nearestBucket(to:)`
- Produces: hover-only view state in `TokenUsageView`

- [ ] **Step 1: Write failing presentation and selection tests**

Create `Tests/CodexRadarTests/TokenUsagePresentationTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexRadar

struct TokenUsagePresentationTests {
  @Test
  func selectedPeriodControlsMetricsAndBuckets() throws {
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [
        TokenUsageEvent(
          timestamp: ISO8601DateFormatter().date(from: "2026-07-15T08:00:00Z")!,
          inputTokens: 100,
          cachedInputTokens: 90,
          outputTokens: 10
        )
      ],
      at: ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let daily = TokenUsagePresentation(snapshot: snapshot, period: .day)
    let monthly = TokenUsagePresentation(snapshot: snapshot, period: .month)

    #expect(daily.buckets.count == 14)
    #expect(monthly.buckets.count == 12)
    #expect(daily.metrics.totalTokens == 110)
    #expect(monthly.metrics.totalTokens == 110)
  }

  @Test
  func nearestBucketUsesTheSmallestAbsoluteTimeDistance() {
    let buckets = [
      bucket(at: 0),
      bucket(at: 100),
      bucket(at: 200),
    ]
    let presentation = TokenUsagePresentation(
      metrics: .zero,
      buckets: buckets
    )

    #expect(presentation.nearestBucket(to: Date(timeIntervalSince1970: 140))?.id == buckets[1].id)
    #expect(presentation.nearestBucket(to: Date(timeIntervalSince1970: 180))?.id == buckets[2].id)
  }

  private func bucket(at timestamp: TimeInterval) -> TokenUsageChartBucket {
    TokenUsageChartBucket(
      startDate: Date(timeIntervalSince1970: timestamp),
      inputTokens: 0,
      outputTokens: 0
    )
  }
}
```

- [ ] **Step 2: Run the presentation tests and verify they fail**

Run:

```bash
swift test --filter TokenUsagePresentationTests
```

Expected: compilation fails because `TokenUsagePresentation` does not exist.

- [ ] **Step 3: Implement the pure presentation model**

Create `Sources/CodexRadar/Models/TokenUsagePresentation.swift`:

```swift
import Foundation

struct TokenUsagePresentation {
  let metrics: TokenUsageMetrics
  let buckets: [TokenUsageChartBucket]

  init(snapshot: TokenUsageSnapshot?, period: TokenUsagePeriod) {
    metrics = snapshot?.metrics(for: period) ?? .zero
    buckets = snapshot?.buckets(for: period) ?? []
  }

  init(
    metrics: TokenUsageMetrics,
    buckets: [TokenUsageChartBucket]
  ) {
    self.metrics = metrics
    self.buckets = buckets
  }

  func nearestBucket(to date: Date) -> TokenUsageChartBucket? {
    buckets.min {
      abs($0.startDate.timeIntervalSince(date))
        < abs($1.startDate.timeIntervalSince(date))
    }
  }
}
```

- [ ] **Step 4: Run the presentation tests**

Run:

```bash
swift test --filter TokenUsagePresentationTests
```

Expected: all tests pass.

- [ ] **Step 5: Replace TokenUsageView rows with a chart overlay**

Replace `Sources/CodexRadar/Views/TokenUsageView.swift` with:

```swift
import Charts
import SwiftUI

struct TokenUsageView: View {
  let snapshot: TokenUsageSnapshot?
  @State private var period: TokenUsagePeriod = .day
  @State private var selectedBucketID: Date?
  @Environment(\.locale) private var locale

  private var presentation: TokenUsagePresentation {
    TokenUsagePresentation(snapshot: snapshot, period: period)
  }

  private var selectedBucket: TokenUsageChartBucket? {
    guard let selectedBucketID else { return nil }
    return presentation.buckets.first { $0.id == selectedBucketID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Token usage")
            .font(.title2.weight(.semibold))
          Text("Local Codex session logs")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Picker("Period", selection: $period) {
          ForEach(TokenUsagePeriod.allCases) { period in
            Text(LocalizedStringKey(period.rawValue)).tag(period)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
      }

      HStack(spacing: 12) {
        MetricTile(
          title: "Total",
          value: presentation.metrics.totalTokens,
          tint: .accentColor,
          locale: locale
        )
        MetricTile(
          title: "Input",
          value: presentation.metrics.inputTokens,
          tint: .blue,
          locale: locale
        )
        MetricTile(
          title: "Output",
          value: presentation.metrics.outputTokens,
          tint: .purple,
          locale: locale
        )
      }

      if snapshot?.hasUsageData != true {
        ContentUnavailableView(
          "No token data",
          systemImage: "chart.bar.xaxis",
          description: Text("Codex session logs will appear here after your next run.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
      } else {
        Chart {
          ForEach(presentation.buckets) { bucket in
            BarMark(
              x: .value("Period", bucket.startDate),
              y: .value("Tokens", bucket.totalTokens)
            )
            .foregroundStyle(Color.accentColor.gradient)
            .cornerRadius(4)
            .opacity(
              selectedBucketID == nil || selectedBucketID == bucket.id ? 1 : 0.42
            )
            .accessibilityLabel(
              Text(
                DisplayFormatting.bucketDate(
                  bucket.startDate,
                  period: period,
                  locale: locale
                )
              )
            )
            .accessibilityValue(Text(accessibilityValue(for: bucket)))
          }

          if let selectedBucket {
            RuleMark(
              x: .value("Selected period", selectedBucket.startDate)
            )
            .foregroundStyle(.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(
              position: .top,
              overflowResolution: .init(
                x: .fit(to: .chart),
                y: .disabled
              )
            ) {
              TokenUsageTooltip(
                bucket: selectedBucket,
                period: period,
                locale: locale
              )
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisValueLabel {
              if let count = value.as(Int.self) {
                Text(DisplayFormatting.tokenCount(count, locale: locale))
              }
            }
          }
        }
        .chartOverlay { proxy in
          GeometryReader { geometry in
            Rectangle()
              .fill(.clear)
              .contentShape(Rectangle())
              .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                  guard let plotFrame = proxy.plotFrame.map({ geometry[$0] }) else {
                    selectedBucketID = nil
                    return
                  }
                  let x = location.x - plotFrame.minX
                  guard x >= 0, x <= plotFrame.width,
                    let date = proxy.value(atX: x, as: Date.self)
                  else {
                    selectedBucketID = nil
                    return
                  }
                  selectedBucketID = presentation.nearestBucket(to: date)?.id
                case .ended:
                  selectedBucketID = nil
                }
              }
          }
        }
        .frame(height: 230)
        .onChange(of: period) {
          selectedBucketID = nil
        }
      }
    }
    .padding(22)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
  }

  private func accessibilityValue(
    for bucket: TokenUsageChartBucket
  ) -> String {
    String(
      format: String(
        localized: "Total %@, Input %@, Output %@",
        bundle: .main,
        locale: locale
      ),
      DisplayFormatting.tokenCount(bucket.totalTokens, locale: locale),
      DisplayFormatting.tokenCount(bucket.inputTokens, locale: locale),
      DisplayFormatting.tokenCount(bucket.outputTokens, locale: locale)
    )
  }
}

private struct MetricTile: View {
  let title: LocalizedStringKey
  let value: Int
  let tint: Color
  let locale: Locale

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .font(.title3.weight(.semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(13)
    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct TokenUsageTooltip: View {
  let bucket: TokenUsageChartBucket
  let period: TokenUsagePeriod
  let locale: Locale

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(
        DisplayFormatting.bucketDate(
          bucket.startDate,
          period: period,
          locale: locale
        )
      )
      .font(.caption.weight(.semibold))

      metric("Total", bucket.totalTokens)
      metric("Input", bucket.inputTokens)
      metric("Output", bucket.outputTokens)
    }
    .padding(10)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
  }

  private func metric(
    _ title: LocalizedStringKey,
    _ value: Int
  ) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .monospacedDigit()
    }
    .font(.caption)
  }
}
```

- [ ] **Step 6: Run presentation and full compile tests**

Run:

```bash
swift test --filter TokenUsagePresentationTests
swift test --filter TokenUsageSnapshotTests
swift test
```

Expected: all tests pass and the Swift Charts overlay compiles for macOS 14.

- [ ] **Step 7: Commit the interaction**

```bash
git add Sources/CodexRadar/Models/TokenUsagePresentation.swift Sources/CodexRadar/Views/TokenUsageView.swift Tests/CodexRadarTests/TokenUsagePresentationTests.swift
git commit -m "feat: add token chart hover details"
```

---

### Task 7: Localize warnings, document behavior, and verify the app

**Files:**

- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/CodexRadarTests/AppLocalizationTests.swift`
- Modify: `README.md`

**Interfaces:**

- Consumes: Repository issue cases and chart accessibility strings
- Produces: complete English and Simplified Chinese UI copy

- [ ] **Step 1: Add failing localization expectations**

Extend the existing Simplified Chinese localization table in
`Tests/CodexRadarTests/AppLocalizationTests.swift`:

```swift
(
  "Token usage source is temporarily unavailable.",
  "Token \u{7528}\u{91CF}\u{6765}\u{6E90}\u{6682}\u{65F6}\u{4E0D}\u{53EF}\u{7528}\u{3002}"
),
(
  "Token usage skipped %lld log files.",
  "Token \u{7528}\u{91CF}\u{8DF3}\u{8FC7}\u{4E86} %lld \u{4E2A}\u{65E5}\u{5FD7}\u{6587}\u{4EF6}\u{3002}"
),
(
  "Token usage cache could not be saved.",
  "\u{65E0}\u{6CD5}\u{4FDD}\u{5B58} Token \u{7528}\u{91CF}\u{7F13}\u{5B58}\u{3002}"
),
("Selected period", "\u{6240}\u{9009}\u{5468}\u{671F}"),
(
  "Total %@, Input %@, Output %@",
  "\u{603B}\u{91CF} %@\u{FF0C}\u{8F93}\u{5165} %@\u{FF0C}\u{8F93}\u{51FA} %@"
),
```

Add matching English expectations to the English table.

- [ ] **Step 2: Run localization tests and verify they fail**

Run:

```bash
swift test --filter AppLocalizationTests
```

Expected: failures report missing Simplified Chinese translations.

- [ ] **Step 3: Add translations and remove dead Cached copy**

Add these entries to both localization files:

```text
"Token usage source is temporarily unavailable." = "Token usage source is temporarily unavailable.";
"Token usage skipped %lld log files." = "Token usage skipped %lld log files.";
"Token usage cache could not be saved." = "Token usage cache could not be saved.";
"Selected period" = "Selected period";
"Total %@, Input %@, Output %@" = "Total %@, Input %@, Output %@";
```

简体中文文件使用以下精确值：

- `Token usage source is temporarily unavailable.` → `Token 用量来源暂时不可用。`
- `Token usage skipped %lld log files.` → `Token 用量跳过了 %lld 个日志文件。`
- `Token usage cache could not be saved.` → `无法保存 Token 用量缓存。`
- `Selected period` → `所选周期`
- `Total %@, Input %@, Output %@` → `总量 %@，输入 %@，输出 %@`

Remove the now-unused `Cached`, `In`, and `Out` entries from both files after confirming:

```bash
rg -n 'Text\\("(Cached|In|Out)"\\)|tokenLabel' Sources/CodexRadar
```

Expected: no production references.

- [ ] **Step 4: Update README behavior**

用以下三条精确正文替换 README 中现有的本地 Token 说明：

> - 只读扫描 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/*.jsonl`，使用版本化本地缓存复用未变化文件的解析结果。
> - 按日、月、年展示 total、input 和 output；当前周期指标与趋势图同步切换，柱状图通过鼠标悬浮展示明细。
> - 参考 CodexBar 的累计快照、interleaved counter 与稳定 session identity 处理；统计为本地日志推算值，不依赖 CodexBar 运行时。

- [ ] **Step 5: Run the complete automated suite**

Run:

```bash
swift test
git diff --check
```

Expected: all Swift tests pass and `git diff --check` prints no output.

- [ ] **Step 6: Build, package, verify, and launch**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: the debug app is packaged, ad-hoc signed, passes bundle verification, launches, and remains running.

- [ ] **Step 7: Perform the real-data acceptance checks**

With the local 1,905-file, 2.24 GiB corpus:

1. Remove only the app's `token-usage` cache directory and open Dashboard.
2. Confirm the cold scan leaves scrolling, window resizing, and period switching responsive.
3. Close and reopen Dashboard; confirm cached Token content appears within 300 ms.
4. Trigger Refresh without changing logs; confirm no visible stall and no JSONL reparse warning.
5. Append one valid Token event to an active Codex session through normal Codex use, then Refresh; confirm only the changed session affects totals.
6. Switch Day, Month, and Year; confirm the three metric cards show today, this month, and this year.
7. Hover the first, middle, and final visible bars; confirm the tooltip remains inside the chart and shows only Period, Total, Input, and Output.
8. Check Light/Dark Mode, English/Simplified Chinese, VoiceOver, and the 980×620 minimum window.

- [ ] **Step 8: Commit localization and documentation**

```bash
git add Sources/CodexRadar/Resources/en.lproj/Localizable.strings Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings Tests/CodexRadarTests/AppLocalizationTests.swift README.md
git commit -m "docs: describe cached token usage"
```

- [ ] **Step 9: Review the complete branch**

Run:

```bash
git status --short
git log --oneline --decorate -8
git diff main...HEAD --stat
```

Expected: the worktree is clean, commits are task-scoped, and the diff contains only Token cache, Dashboard interaction, localization, tests, and documentation changes.
