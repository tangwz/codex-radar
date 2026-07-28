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
