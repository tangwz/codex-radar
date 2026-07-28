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
      refreshTokenUsageSource: { _, _ in await source.refresh() },
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

  @MainActor
  @Test
  func crossingMidnightTriggersOneRefreshAndPublishesTheNewDay() async throws {
    let timeZone = TimeZone.autoupdatingCurrent
    let beforeMidnight = try localDate(
      year: 2026,
      month: 7,
      day: 31,
      hour: 23,
      minute: 59,
      second: 59,
      timeZone: timeZone
    )
    let midnight = try localDate(
      year: 2026,
      month: 8,
      day: 1,
      hour: 0,
      minute: 0,
      second: 0,
      timeZone: timeZone
    )
    let afterMidnight = midnight.addingTimeInterval(1)
    let initial = snapshot(
      events: [event(at: beforeMidnight, total: 10)],
      generatedAt: beforeMidnight,
      timeZone: timeZone
    )
    let rolled = snapshot(
      events: [
        event(at: beforeMidnight, total: 10),
        event(at: afterMidnight, total: 20),
      ],
      generatedAt: afterMidnight,
      timeZone: timeZone
    )
    let source = SequencedTokenUsageSource(snapshots: [initial, rolled])
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let clock = MutableDate(beforeMidnight)
    let store = makeFreshnessBoundaryStore(
      refresh: {
        await source.refresh(timeZone: $0, freshnessCutoff: $1)
      },
      waiter: waiter,
      now: { clock.value }
    )
    defer { store.stopMonitoring() }

    store.startMonitoring()
    await source.waitForCallCount(1)
    await waitForSnapshot(initial, in: store)
    await waiter.waitForCount(1)

    clock.value = afterMidnight
    await waiter.fireNext()
    await source.waitForCallCount(2)
    await waitForSnapshot(rolled, in: store)

    #expect(await source.callCount == 2)
    #expect(await source.freshnessCutoff(at: 0) == nil)
    #expect(await source.freshnessCutoff(at: 1) == midnight)
    #expect(store.tokenUsageSnapshot?.metrics(for: .day).totalTokens == 20)
  }

  @MainActor
  @Test
  func yearBoundaryRebuildsCurrentMonthAndYearMetrics() async throws {
    let timeZone = TimeZone.autoupdatingCurrent
    let previousYear = try localDate(
      year: 2026,
      month: 12,
      day: 31,
      hour: 23,
      minute: 59,
      second: 59,
      timeZone: timeZone
    )
    let currentYear = try localDate(
      year: 2027,
      month: 1,
      day: 1,
      hour: 0,
      minute: 0,
      second: 1,
      timeZone: timeZone
    )
    let initial = snapshot(
      events: [event(at: previousYear, total: 30)],
      generatedAt: previousYear,
      timeZone: timeZone
    )
    let rolled = snapshot(
      events: [
        event(at: previousYear, total: 30),
        event(at: currentYear, total: 40),
      ],
      generatedAt: currentYear,
      timeZone: timeZone
    )
    let source = SequencedTokenUsageSource(snapshots: [initial, rolled])
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let clock = MutableDate(previousYear)
    let store = makeBoundaryStore(
      refresh: { timeZone in await source.refresh(timeZone: timeZone) },
      waiter: waiter,
      now: { clock.value }
    )
    defer { store.stopMonitoring() }

    store.startMonitoring()
    await source.waitForCallCount(1)
    await waitForSnapshot(initial, in: store)
    await waiter.waitForCount(1)
    clock.value = currentYear
    await waiter.fireNext()
    await source.waitForCallCount(2)
    await waitForSnapshot(rolled, in: store)

    #expect(store.tokenUsageSnapshot?.metrics(for: .month).totalTokens == 40)
    #expect(store.tokenUsageSnapshot?.metrics(for: .year).totalTokens == 40)
  }

  @MainActor
  @Test
  func stopPreventsBoundaryTriggeredLateResultFromPublishing() async throws {
    let timeZone = TimeZone.autoupdatingCurrent
    let beforeMidnight = try localDate(
      year: 2026,
      month: 7,
      day: 31,
      hour: 23,
      minute: 59,
      second: 59,
      timeZone: timeZone
    )
    let afterMidnight = try localDate(
      year: 2026,
      month: 8,
      day: 1,
      hour: 0,
      minute: 0,
      second: 1,
      timeZone: timeZone
    )
    let initial = snapshot(
      events: [event(at: beforeMidnight, total: 10)],
      generatedAt: beforeMidnight,
      timeZone: timeZone
    )
    let late = snapshot(
      events: [event(at: afterMidnight, total: 99)],
      generatedAt: afterMidnight,
      timeZone: timeZone
    )
    let source = SuspendedBoundaryTokenUsageSource(initial: initial)
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let clock = MutableDate(beforeMidnight)
    let store = makeBoundaryStore(
      refresh: { timeZone in await source.refresh(timeZone: timeZone) },
      waiter: waiter,
      now: { clock.value }
    )

    store.startMonitoring()
    await source.waitForCallCount(1)
    await waitForSnapshot(initial, in: store)
    await waiter.waitForCount(1)
    clock.value = afterMidnight
    await waiter.fireNext()
    await source.waitForCallCount(2)

    store.stopMonitoring()
    await source.completeBoundaryRefresh(with: late)
    for _ in 0..<50 {
      await Task.yield()
    }

    #expect(store.tokenUsageSnapshot == initial)
  }

  @MainActor
  @Test
  func timeZoneChangeReplacesSameInstantBoundaryWait() async throws {
    let now = Date(timeIntervalSince1970: 1_788_192_000)
    let firstTimeZone = try #require(TimeZone(identifier: "Etc/UTC"))
    let secondTimeZone = try #require(TimeZone(identifier: "Africa/Abidjan"))
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let store = makeBoundaryStore(
      refresh: { timeZone in
        TokenUsageRepositoryResult(
          snapshot: snapshot(events: [], generatedAt: now, timeZone: timeZone),
          issues: []
        )
      },
      waiter: waiter,
      now: { now }
    )
    defer { store.stopMonitoring() }

    store.startMonitoring()
    await waiter.waitForCount(1)
    await store.refreshTokenUsage(timeZone: firstTimeZone)
    for _ in 0..<20 {
      await Task.yield()
    }
    let waitCountBeforeChange = await waiter.dates.count

    await store.refreshTokenUsage(timeZone: secondTimeZone)
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(await waiter.dates.count == waitCountBeforeChange + 1)
  }

  @MainActor
  @Test
  func recoveryRefreshesUsageAndReschedulesAfterMissedBoundary() async throws {
    let timeZone = TimeZone.autoupdatingCurrent
    let beforeMidnight = try localDate(
      year: 2026,
      month: 7,
      day: 31,
      hour: 23,
      minute: 59,
      second: 59,
      timeZone: timeZone
    )
    let afterMidnight = try localDate(
      year: 2026,
      month: 8,
      day: 1,
      hour: 0,
      minute: 0,
      second: 1,
      timeZone: timeZone
    )
    let initial = snapshot(
      events: [event(at: beforeMidnight, total: 10)],
      generatedAt: beforeMidnight,
      timeZone: timeZone
    )
    let recovered = snapshot(
      events: [event(at: afterMidnight, total: 20)],
      generatedAt: afterMidnight,
      timeZone: timeZone
    )
    let source = SequencedTokenUsageSource(snapshots: [initial, recovered])
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let clock = MutableDate(beforeMidnight)
    let store = makeFreshnessBoundaryStore(
      refresh: {
        await source.refresh(timeZone: $0, freshnessCutoff: $1)
      },
      waiter: waiter,
      now: { clock.value }
    )
    defer { store.stopMonitoring() }

    store.startMonitoring()
    await source.waitForCallCount(1)
    await waitForSnapshot(initial, in: store)
    await waiter.waitForCount(1)

    clock.value = afterMidnight
    await store.monitoringDidRecover()
    for _ in 0..<50 {
      await Task.yield()
    }

    #expect(await source.callCount == 2)
    #expect(await source.freshnessCutoff(at: 0) == nil)
    #expect(await source.freshnessCutoff(at: 1) == afterMidnight)
    #expect(store.tokenUsageSnapshot == recovered)
    #expect(await waiter.dates.count == 2)
  }

  @MainActor
  @Test
  func forecastAndTokenIssuesRecoverIndependently() async {
    let tokenSource = TokenUsageResultQueue([
      TokenUsageRepositoryResult(snapshot: nil, issues: [.sourceUnavailable]),
      TokenUsageRepositoryResult(snapshot: nil, issues: []),
    ])
    let forecastSource = ForecastResultQueue([
      .failure(.invalidResponse),
      .success(.notModified),
      .failure(.invalidResponse),
    ])
    let store = DashboardStore(
      refreshTokenUsageSource: { _, _ in await tokenSource.next() },
      formatTokenUsageIssue: { _ in "Token issue" },
      fetchForecast: { _ in try await forecastSource.next() },
      prepareNotifications: {},
      observeForecast: { _ in },
      formatForecastIssue: { _ in "Forecast issue" },
      pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
      sleep: { _ in },
      observesWakeEvents: false
    )

    await store.refresh()
    #expect(store.issues == ["Forecast issue", "Token issue"])

    await store.refreshForecast()
    #expect(store.issues == ["Token issue"])

    await store.refreshForecast()
    #expect(store.issues == ["Forecast issue", "Token issue"])

    await store.refreshTokenUsage(timeZone: .autoupdatingCurrent)
    #expect(store.issues == ["Forecast issue"])
  }

  @MainActor
  @Test
  func recoveryStartingAfterStopDoesNotRefreshUsage() async {
    let initial = snapshot(total: 10)
    let source = SequencedTokenUsageSource(
      snapshots: [initial, snapshot(total: 20)]
    )
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let store = makeBoundaryStore(
      refresh: { timeZone in await source.refresh(timeZone: timeZone) },
      waiter: waiter,
      now: { initial.generatedAt }
    )

    store.startMonitoring()
    await source.waitForCallCount(1)
    await waitForSnapshot(initial, in: store)
    store.stopMonitoring()

    await store.monitoringDidRecover()

    #expect(await source.callCount == 1)
    #expect(store.tokenUsageSnapshot == initial)
  }

  @MainActor
  @Test
  func futureCachedTimestampCannotPostponeNextDayBoundary() async throws {
    let timeZone = TimeZone.autoupdatingCurrent
    let current = try localDate(
      year: 2026,
      month: 7,
      day: 28,
      hour: 12,
      minute: 0,
      second: 0,
      timeZone: timeZone
    )
    let future = try localDate(
      year: 2026,
      month: 8,
      day: 10,
      hour: 12,
      minute: 0,
      second: 0,
      timeZone: timeZone
    )
    let cached = snapshot(
      events: [event(at: current, total: 10)],
      generatedAt: future,
      timeZone: timeZone
    )
    let source = ControlledTokenUsageSource(
      cached: cached,
      fresh: cached,
      shouldSuspend: true
    )
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let store = makeBoundaryStore(
      loadCached: { _ in await source.cachedSnapshot() },
      refresh: { _ in await source.refresh() },
      waiter: waiter,
      now: { current }
    )
    store.startMonitoring()
    await source.waitForRefresh()
    await waitForSnapshot(cached, in: store)
    for _ in 0..<20 {
      await Task.yield()
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let expectedBoundary = try #require(
      calendar.dateInterval(of: .day, for: current)?.end
    )
    #expect(await waiter.dates.last == expectedBoundary)

    await source.completeRefresh()
    store.stopMonitoring()
  }

  @MainActor
  @Test
  func stoppedRecoveryCannotAttachToRestartedMonitoring() async {
    let initial = snapshot(total: 10)
    let restarted = snapshot(total: 20)
    let staleRecovery = snapshot(total: 99)
    let source = SequencedTokenUsageSource(
      snapshots: [initial, restarted, staleRecovery]
    )
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let recoveryBarrier = ControlledRecoveryBarrier()
    let store = makeBoundaryStore(
      refresh: { timeZone in await source.refresh(timeZone: timeZone) },
      waiter: waiter,
      now: { initial.generatedAt },
      recoveryBarrier: {
        await recoveryBarrier.pause()
      }
    )

    store.startMonitoring()
    await source.waitForCallCount(1)
    await waitForSnapshot(initial, in: store)

    let recovery = Task {
      await store.monitoringDidRecover()
    }
    await recoveryBarrier.waitUntilEntered()

    store.stopMonitoring()
    store.startMonitoring()
    await source.waitForCallCount(2)
    await waitForSnapshot(restarted, in: store)

    await recoveryBarrier.release()
    await recovery.value
    for _ in 0..<50 {
      await Task.yield()
    }

    #expect(await source.callCount == 2)
    #expect(store.tokenUsageSnapshot == restarted)
    store.stopMonitoring()
  }

  @MainActor
  @Test
  func recoveryPublishesTokenUsageWhileForecastIsStillPending() async {
    let initial = snapshot(total: 10)
    let recovered = snapshot(total: 20)
    let tokenSource = SequencedTokenUsageSource(snapshots: [initial, recovered])
    let forecastSource = ControlledRecoveryForecastSource()
    let waiter = ControlledTokenUsageBoundaryWaiter()
    let store = makeBoundaryStore(
      refresh: { timeZone in await tokenSource.refresh(timeZone: timeZone) },
      fetchForecast: { _ in await forecastSource.fetch() },
      waiter: waiter,
      now: { initial.generatedAt }
    )

    store.startMonitoring()
    await tokenSource.waitForCallCount(1)
    await forecastSource.waitForCallCount(1)
    await forecastSource.completeNext()
    await waitForSnapshot(initial, in: store)

    let recovery = Task {
      await store.monitoringDidRecover()
    }
    await tokenSource.waitForCallCount(2)
    await forecastSource.waitForCallCount(2)
    for _ in 0..<50 {
      await Task.yield()
    }

    #expect(store.tokenUsageSnapshot == recovered)

    await forecastSource.completeNext()
    await recovery.value
    store.stopMonitoring()
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

private actor SequencedTokenUsageSource {
  private var snapshots: [TokenUsageSnapshot]
  private var freshnessCutoffs: [Date?] = []
  private(set) var callCount = 0

  init(snapshots: [TokenUsageSnapshot]) {
    self.snapshots = snapshots
  }

  func refresh(timeZone: TimeZone) -> TokenUsageRepositoryResult {
    refresh(timeZone: timeZone, freshnessCutoff: nil)
  }

  func refresh(
    timeZone: TimeZone,
    freshnessCutoff: Date?
  ) -> TokenUsageRepositoryResult {
    callCount += 1
    freshnessCutoffs.append(freshnessCutoff)
    guard !snapshots.isEmpty else {
      return TokenUsageRepositoryResult(snapshot: nil, issues: [])
    }
    return TokenUsageRepositoryResult(snapshot: snapshots.removeFirst(), issues: [])
  }

  func waitForCallCount(_ count: Int) async {
    while callCount < count {
      await Task.yield()
    }
  }

  func freshnessCutoff(at index: Int) -> Date? {
    freshnessCutoffs[index]
  }
}

private actor ControlledRecoveryForecastSource {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private(set) var callCount = 0

  func fetch() async -> ResetForecastFetchResult {
    callCount += 1
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    return .notModified
  }

  func waitForCallCount(_ count: Int) async {
    while callCount < count {
      await Task.yield()
    }
  }

  func completeNext() {
    guard !continuations.isEmpty else {
      Issue.record("No pending forecast request to complete.")
      return
    }
    continuations.removeFirst().resume()
  }
}

private actor SuspendedBoundaryTokenUsageSource {
  private let initial: TokenUsageSnapshot
  private(set) var callCount = 0
  private var continuation: CheckedContinuation<TokenUsageRepositoryResult, Never>?

  init(initial: TokenUsageSnapshot) {
    self.initial = initial
  }

  func refresh(timeZone: TimeZone) async -> TokenUsageRepositoryResult {
    callCount += 1
    if callCount == 1 {
      return TokenUsageRepositoryResult(snapshot: initial, issues: [])
    }
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitForCallCount(_ count: Int) async {
    while callCount < count {
      await Task.yield()
    }
  }

  func completeBoundaryRefresh(with snapshot: TokenUsageSnapshot) {
    continuation?.resume(
      returning: TokenUsageRepositoryResult(snapshot: snapshot, issues: [])
    )
    continuation = nil
  }
}

private actor TokenUsageResultQueue {
  private var results: [TokenUsageRepositoryResult]

  init(_ results: [TokenUsageRepositoryResult]) {
    self.results = results
  }

  func next() -> TokenUsageRepositoryResult {
    guard !results.isEmpty else {
      return TokenUsageRepositoryResult(snapshot: nil, issues: [])
    }
    return results.removeFirst()
  }
}

private actor ForecastResultQueue {
  private var results: [Result<ResetForecastFetchResult, ResetForecastServiceError>]

  init(_ results: [Result<ResetForecastFetchResult, ResetForecastServiceError>]) {
    self.results = results
  }

  func next() throws -> ResetForecastFetchResult {
    guard !results.isEmpty else { return .notModified }
    return try results.removeFirst().get()
  }
}

private final class MutableDate: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Date

  init(_ value: Date) {
    storage = value
  }

  var value: Date {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private actor ControlledRecoveryBarrier {
  private var entered = false
  private var continuation: CheckedContinuation<Void, Never>?

  func pause() async {
    entered = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilEntered() async {
    while !entered {
      await Task.yield()
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor ControlledTokenUsageBoundaryWaiter {
  private struct Wait {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var waits: [Wait] = []
  private(set) var dates: [Date] = []

  func wait(until date: Date) async throws {
    let id = UUID()
    dates.append(date)
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waits.append(Wait(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task {
        await self.cancel(id: id)
      }
    }
  }

  func waitForCount(_ count: Int) async {
    while dates.count < count {
      await Task.yield()
    }
  }

  func fireNext() {
    guard !waits.isEmpty else {
      Issue.record("No pending token usage boundary wait to fire.")
      return
    }
    waits.removeFirst().continuation.resume()
  }

  private func cancel(id: UUID) {
    guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
    waits.remove(at: index).continuation.resume(throwing: CancellationError())
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
    refreshTokenUsageSource: { _, _ in
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

@MainActor
private func makeBoundaryStore(
  loadCached: @escaping @Sendable (TimeZone) async -> TokenUsageSnapshot? = {
    _ in nil
  },
  refresh: @escaping @Sendable (TimeZone) async -> TokenUsageRepositoryResult,
  fetchForecast:
    @escaping @Sendable (String?) async throws -> ResetForecastFetchResult = {
      _ in .notModified
    },
  waiter: ControlledTokenUsageBoundaryWaiter,
  now: @escaping @Sendable () -> Date,
  recoveryBarrier: @escaping @MainActor @Sendable () async -> Void = {}
) -> DashboardStore {
  DashboardStore(
    loadCachedTokenUsage: loadCached,
    refreshTokenUsageSource: { timeZone, _ in
      await refresh(timeZone)
    },
    fetchForecast: fetchForecast,
    prepareNotifications: {},
    observeForecast: { _ in },
    formatForecastIssue: { $0 ?? "" },
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: { _ in throw CancellationError() },
    waitUntilTokenUsageBoundary: {
      try await waiter.wait(until: $0)
    },
    now: now,
    recoveryBarrier: recoveryBarrier,
    observesWakeEvents: false
  )
}

@MainActor
private func makeFreshnessBoundaryStore(
  refresh:
    @escaping @Sendable (TimeZone, Date?) async -> TokenUsageRepositoryResult,
  waiter: ControlledTokenUsageBoundaryWaiter,
  now: @escaping @Sendable () -> Date
) -> DashboardStore {
  DashboardStore(
    refreshTokenUsageSource: refresh,
    fetchForecast: { _ in .notModified },
    prepareNotifications: {},
    observeForecast: { _ in },
    formatForecastIssue: { $0 ?? "" },
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: { _ in throw CancellationError() },
    waitUntilTokenUsageBoundary: {
      try await waiter.wait(until: $0)
    },
    now: now,
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

private func snapshot(
  events: [TokenUsageEvent],
  generatedAt: Date,
  timeZone: TimeZone
) -> TokenUsageSnapshot {
  TokenUsageSnapshotBuilder.make(
    events: events,
    at: generatedAt,
    timeZone: timeZone
  )
}

private func event(at timestamp: Date, total: Int) -> TokenUsageEvent {
  TokenUsageEvent(
    timestamp: timestamp,
    inputTokens: total,
    cachedInputTokens: 0,
    outputTokens: 0
  )
}

private func localDate(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  timeZone: TimeZone
) throws -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  return try #require(
    calendar.date(
      from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
      )
    )
  )
}

@MainActor
private func waitForSnapshot(
  _ snapshot: TokenUsageSnapshot,
  in store: DashboardStore
) async {
  for _ in 0..<100 where store.tokenUsageSnapshot != snapshot {
    await Task.yield()
  }
  if store.tokenUsageSnapshot != snapshot {
    Issue.record("Timed out waiting for token usage snapshot.")
  }
}
