import Foundation
import Testing

@testable import CodexRadar

struct DashboardStoreForecastTests {
  @MainActor
  @Test
  func appliesUpdatedForecastETagAndNotificationObservation() async {
    let forecast = storeForecast(signalID: "signal-1")
    let notifications = ForecastObservationRecorder()
    let store = makeStore(
      fetch: { _ in .updated(forecast, etag: #""revision-1""#) },
      observe: { await notifications.record($0) }
    )

    await store.refreshForecast()

    #expect(store.forecast == forecast)
    #expect(store.forecastETag == #""revision-1""#)
    #expect(store.consecutiveForecastFailures == 0)
    #expect(await notifications.forecasts == [forecast])
    #expect(store.issues.isEmpty)
  }

  @MainActor
  @Test
  func treatsNotModifiedAsSuccessAndReobservesCurrentForecast() async {
    let forecast = storeForecast(signalID: "signal-1")
    let fetcher = ForecastResultQueue([
      .success(.updated(forecast, etag: #""revision-1""#)),
      .success(.notModified),
    ])
    let notifications = ForecastObservationRecorder()
    let store = makeStore(
      fetch: { try await fetcher.fetch(etag: $0) },
      observe: { await notifications.record($0) }
    )

    await store.refreshForecast()
    await store.refreshForecast()

    #expect(store.forecast == forecast)
    #expect(store.forecastETag == #""revision-1""#)
    #expect(store.consecutiveForecastFailures == 0)
    #expect(await notifications.forecasts == [forecast, forecast])
    #expect(store.issues.isEmpty)
  }

  @MainActor
  @Test
  func keepsLastSnapshotAndSingleIssueUntilRecovery() async {
    let recovered = storeForecast(signalID: "signal-2")
    let fetcher = ForecastResultQueue([
      .failure(ResetForecastServiceError.invalidResponse),
      .failure(ResetForecastServiceError.invalidResponse),
      .success(.updated(recovered, etag: nil)),
    ])
    let store = makeStore(fetch: { try await fetcher.fetch(etag: $0) })

    await store.refreshForecast()
    #expect(store.forecast == .placeholder)
    #expect(store.consecutiveForecastFailures == 1)
    #expect(store.issues.count == 1)

    await store.refreshForecast()
    #expect(store.consecutiveForecastFailures == 2)
    #expect(store.issues.count == 1)

    await store.refreshForecast()
    #expect(store.forecast == recovered)
    #expect(store.consecutiveForecastFailures == 0)
    #expect(store.issues.isEmpty)
  }

  @MainActor
  @Test
  func replacesAndClearsForecastIssueAcrossLanguageChanges() async {
    let defaults = UserDefaults.standard
    let previousLanguage = defaults.object(forKey: AppLanguage.defaultsKey)
    defer {
      if let previousLanguage {
        defaults.set(previousLanguage, forKey: AppLanguage.defaultsKey)
      } else {
        defaults.removeObject(forKey: AppLanguage.defaultsKey)
      }
    }

    let fetcher = ForecastResultQueue([
      .failure(ResetForecastServiceError.invalidResponse),
      .failure(ResetForecastServiceError.invalidResponse),
      .success(.notModified),
    ])
    let formatter = MutableForecastIssueFormatter(
      template: "English forecast issue: %@"
    )
    let store = makeStore(
      fetch: { try await fetcher.fetch(etag: $0) },
      formatForecastIssue: { formatter.format(message: $0) }
    )

    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
    await store.refreshForecast()
    let englishIssue = store.issues.first
    #expect(store.issues.count == 1)

    defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.defaultsKey)
    formatter.template = "Chinese forecast issue: %@"
    await store.refreshForecast()
    #expect(store.issues.count == 1)
    #expect(store.issues.first != englishIssue)

    await store.refreshForecast()
    #expect(store.issues.isEmpty)
  }

  @MainActor
  @Test
  func repeatedStartMonitoringCreatesOnlyOneLoop() async {
    let fetcher = ForecastResultQueue([.success(.notModified)])
    let store = makeStore(fetch: { try await fetcher.fetch(etag: $0) })

    store.startMonitoring()
    store.startMonitoring()
    for _ in 0..<20 where await fetcher.callCount == 0 {
      await Task.yield()
    }
    store.stopMonitoring()

    #expect(await fetcher.callCount == 1)
  }

  @MainActor
  @Test
  func suspendedNotificationAuthorizationDoesNotBlockInitialForecastFetch() async {
    let fetcher = ForecastResultQueue([.success(.notModified)])
    let preparation = CancellationRecorder()
    let store = makeStore(
      fetch: { try await fetcher.fetch(etag: $0) },
      prepare: {
        do {
          try await Task.sleep(for: .seconds(3_600))
        } catch {
          await preparation.recordCancellation()
        }
      }
    )

    store.startMonitoring()
    for _ in 0..<20 where await fetcher.callCount == 0 {
      await Task.yield()
    }

    #expect(await fetcher.callCount == 1)

    store.stopMonitoring()
    for _ in 0..<20 where !(await preparation.wasCancelled) {
      await Task.yield()
    }
    #expect(await preparation.wasCancelled)
  }

  @MainActor
  @Test
  func concurrentManualRefreshesShareTheInFlightRequest() async {
    let calls = CallCounter()
    let store = makeStore(fetch: { _ in
      await calls.increment()
      try await Task.sleep(for: .milliseconds(50))
      return .notModified
    })

    let first = Task { await store.refreshForecast() }
    await Task.yield()
    await store.refreshForecast()
    await first.value

    #expect(await calls.count == 1)
  }

  @MainActor
  @Test
  func recoveryDuringInFlightFetchQueuesOneNonConcurrentRefresh() async {
    let fetcher = ControlledForecastFetcher()
    let store = makeStore(fetch: { try await fetcher.fetch(etag: $0) })

    store.startMonitoring()
    for _ in 0..<40 where await fetcher.callCount < 1 {
      await Task.yield()
    }

    let recovery = Task { await store.monitoringDidRecover() }
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(await fetcher.callCount == 1)

    await fetcher.completeNext(with: .success(.notModified))
    for _ in 0..<40 where await fetcher.callCount < 2 {
      await Task.yield()
    }

    #expect(await fetcher.callCount == 2)
    #expect(await fetcher.maximumActiveCount == 1)

    await fetcher.completeNext(with: .success(.notModified))
    await recovery.value
    store.stopMonitoring()
  }

  @MainActor
  @Test
  func multipleRecoveryEventsDuringInFlightFetchCoalesce() async {
    let fetcher = ControlledForecastFetcher()
    let store = makeStore(fetch: { try await fetcher.fetch(etag: $0) })

    store.startMonitoring()
    for _ in 0..<40 where await fetcher.callCount < 1 {
      await Task.yield()
    }

    let first = Task { await store.monitoringDidRecover() }
    let second = Task { await store.monitoringDidRecover() }
    let third = Task { await store.monitoringDidRecover() }
    for _ in 0..<10 {
      await Task.yield()
    }

    await fetcher.completeNext(with: .success(.notModified))
    for _ in 0..<40 where await fetcher.callCount < 2 {
      await Task.yield()
    }
    await fetcher.completeNext(with: .success(.notModified))
    await first.value
    await second.value
    await third.value
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(await fetcher.callCount == 2)
    #expect(await fetcher.maximumActiveCount == 1)
    store.stopMonitoring()
  }

  @MainActor
  @Test
  func recoveryFailureReplacesSuccessPollWithFiveSecondRetry() async {
    let fetcher = ForecastResultQueue([
      .success(.notModified),
      .failure(ResetForecastServiceError.invalidResponse),
    ])
    let sleeper = PollingSleepRecorder()
    let store = makeStore(
      fetch: { try await fetcher.fetch(etag: $0) },
      sleep: { try await sleeper.sleep(for: $0) }
    )

    store.startMonitoring()
    for _ in 0..<40 where await sleeper.delays.isEmpty {
      await Task.yield()
    }
    #expect(await sleeper.delays.first == .seconds(60))

    await store.monitoringDidRecover()
    for _ in 0..<40 where await sleeper.delays.count < 2 {
      await Task.yield()
    }

    #expect(await sleeper.delays.last == .seconds(5))
    store.stopMonitoring()
  }

  @MainActor
  @Test
  func immediateRestartWaitsForOldNonCooperativeFetchThenContinuesCurrentGeneration() async {
    let oldForecast = storeForecast(signalID: "old-signal")
    let currentForecast = storeForecast(signalID: "current-signal")
    let fetcher = ControlledForecastFetcher()
    let sleeper = PollingSleepRecorder()
    let store = makeStore(
      fetch: { try await fetcher.fetch(etag: $0) },
      sleep: { try await sleeper.sleep(for: $0) }
    )

    store.startMonitoring()
    for _ in 0..<40 where await fetcher.callCount < 1 {
      await Task.yield()
    }

    store.stopMonitoring()
    store.startMonitoring()
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(await fetcher.callCount == 1)
    #expect(await fetcher.maximumActiveCount == 1)

    await fetcher.completeNext(
      with: .success(.updated(oldForecast, etag: #""old-generation""#))
    )
    for _ in 0..<40 where await fetcher.callCount < 2 {
      await Task.yield()
    }

    guard await fetcher.callCount == 2 else {
      Issue.record("The current generation did not start its queued fetch.")
      store.stopMonitoring()
      return
    }
    #expect(store.forecast == .placeholder)
    #expect(store.forecastETag == nil)
    #expect(store.consecutiveForecastFailures == 0)
    #expect(store.issues.isEmpty)
    #expect(store.lastUpdated == nil)
    #expect(await sleeper.delays.isEmpty)
    #expect(await fetcher.maximumActiveCount == 1)

    await fetcher.completeNext(
      with: .success(.updated(currentForecast, etag: #""current-generation""#))
    )
    for _ in 0..<40 where await sleeper.delays.isEmpty {
      await Task.yield()
    }

    #expect(store.forecast == currentForecast)
    #expect(store.forecastETag == #""current-generation""#)
    #expect(await sleeper.delays.first == .seconds(60))
    #expect(await fetcher.maximumActiveCount == 1)
    store.stopMonitoring()
  }
}

@MainActor
private func makeStore(
  fetch: @escaping @Sendable (String?) async throws -> ResetForecastFetchResult,
  prepare: @escaping @MainActor @Sendable () async -> Void = {},
  observe: @escaping @MainActor @Sendable (ResetForecast) async -> Void = { _ in },
  formatForecastIssue: @escaping @MainActor @Sendable (String?) -> String = {
    String(format: AppLocalization.string("Reset forecast: %@"), $0 ?? "")
  },
  sleep: @escaping @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }
) -> DashboardStore {
  DashboardStore(
    scanSessions: { [] },
    fetchForecast: fetch,
    prepareNotifications: prepare,
    observeForecast: observe,
    formatForecastIssue: formatForecastIssue,
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: sleep,
    observesWakeEvents: false
  )
}

@MainActor
private final class MutableForecastIssueFormatter {
  var template: String

  init(template: String) {
    self.template = template
  }

  func format(message: String?) -> String {
    String(format: template, message ?? "")
  }
}

private func storeForecast(signalID: String?) -> ResetForecast {
  ResetForecast(
    schemaVersion: "1.0",
    monitoredAt: Date(timeIntervalSince1970: 1_700_000_000),
    stale: false,
    status: .announced,
    recommendedAction: .wait,
    message: "Reset announced.",
    signalID: signalID,
    timing: ResetTiming(kind: .imminent),
    sourceURL: nil,
    posts: []
  )
}

private actor ForecastObservationRecorder {
  private(set) var forecasts: [ResetForecast] = []

  func record(_ forecast: ResetForecast) {
    forecasts.append(forecast)
  }
}

private actor ForecastResultQueue {
  private var results: [Result<ResetForecastFetchResult, Error>]
  private(set) var callCount = 0

  init(_ results: [Result<ResetForecastFetchResult, Error>]) {
    self.results = results
  }

  func fetch(etag: String?) throws -> ResetForecastFetchResult {
    callCount += 1
    guard !results.isEmpty else { return .notModified }
    return try results.removeFirst().get()
  }
}

private actor CallCounter {
  private(set) var count = 0

  func increment() {
    count += 1
  }
}

private actor CancellationRecorder {
  private(set) var wasCancelled = false

  func recordCancellation() {
    wasCancelled = true
  }
}

private actor ControlledForecastFetcher {
  enum Outcome: Sendable {
    case success(ResetForecastFetchResult)
    case failure(ResetForecastServiceError)
  }

  private var continuations: [CheckedContinuation<Outcome, Never>] = []
  private(set) var callCount = 0
  private(set) var maximumActiveCount = 0
  private var activeCount = 0

  func fetch(etag: String?) async throws -> ResetForecastFetchResult {
    callCount += 1
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    let outcome = await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    activeCount -= 1
    switch outcome {
    case .success(let result):
      return result
    case .failure(let error):
      throw error
    }
  }

  func completeNext(with outcome: Outcome) {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume(returning: outcome)
  }
}

private actor PollingSleepRecorder {
  private(set) var delays: [Duration] = []

  func sleep(for delay: Duration) async throws {
    delays.append(delay)
    try await Task.sleep(for: .seconds(3_600))
  }
}
