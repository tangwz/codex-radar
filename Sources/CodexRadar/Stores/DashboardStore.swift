import Foundation

private enum ForecastRefreshTrigger: Int {
  case scheduled
  case manual
  case recovery
}

private struct PendingForecastRefresh {
  let generation: UInt64
  var trigger: ForecastRefreshTrigger
  var waiters: [CheckedContinuation<Void, Never>]

  mutating func merge(
    trigger: ForecastRefreshTrigger,
    waiter: CheckedContinuation<Void, Never>?
  ) {
    if trigger.rawValue > self.trigger.rawValue {
      self.trigger = trigger
    }
    if let waiter {
      waiters.append(waiter)
    }
  }
}

@MainActor
final class DashboardStore: ObservableObject {
  @Published private(set) var forecast = ResetForecast.placeholder
  @Published private(set) var tokenEvents: [TokenUsageEvent] = []
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var issues: [String] = []

  private(set) var forecastETag: String?
  private(set) var consecutiveForecastFailures = 0

  private let scanSessions: @Sendable () throws -> [TokenUsageEvent]
  private let fetchForecast: @Sendable (String?) async throws -> ResetForecastFetchResult
  private let prepareNotifications: @MainActor @Sendable () async -> Void
  private let observeForecast: @MainActor @Sendable (ResetForecast) async -> Void
  private let pollingSchedule: ResetPollingSchedule
  private let sleep: @Sendable (Duration) async throws -> Void
  private let observesWakeEvents: Bool

  private var isMonitoring = false
  private var forecastSchedulerTask: Task<Void, Never>?
  private var forecastSchedulerContinuation: AsyncStream<Void>.Continuation?
  private var pollingTimerTask: Task<Void, Never>?
  private var notificationPreparationTask: Task<Void, Never>?
  private var initialRefreshTask: Task<Void, Never>?
  private var wakeObserver: MonitoringWakeObserver?
  private var pendingForecastRefresh: PendingForecastRefresh?
  private var forecastFetchInProgress = false
  private var currentRefreshWaiters: [CheckedContinuation<Void, Never>] = []
  private var refreshActivityCount = 0
  private var forecastGeneration: UInt64 = 0
  private var activeFetchGeneration: UInt64?

  init(
    sessionScanner: CodexSessionScanner = CodexSessionScanner(),
    forecastService: ResetForecastService = ResetForecastService(),
    notificationService: ResetNotificationService = ResetNotificationService()
  ) {
    scanSessions = { try sessionScanner.scan() }
    fetchForecast = { try await forecastService.fetch(etag: $0) }
    prepareNotifications = { await notificationService.prepare() }
    observeForecast = { await notificationService.observe($0) }
    pollingSchedule = ResetPollingSchedule { Int.random(in: -10...10) }
    sleep = { try await Task.sleep(for: $0) }
    observesWakeEvents = true
  }

  init(
    scanSessions: @escaping @Sendable () throws -> [TokenUsageEvent],
    fetchForecast: @escaping @Sendable (String?) async throws -> ResetForecastFetchResult,
    prepareNotifications: @escaping @MainActor @Sendable () async -> Void,
    observeForecast: @escaping @MainActor @Sendable (ResetForecast) async -> Void,
    pollingSchedule: ResetPollingSchedule,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    observesWakeEvents: Bool
  ) {
    self.scanSessions = scanSessions
    self.fetchForecast = fetchForecast
    self.prepareNotifications = prepareNotifications
    self.observeForecast = observeForecast
    self.pollingSchedule = pollingSchedule
    self.sleep = sleep
    self.observesWakeEvents = observesWakeEvents
  }

  func startMonitoring() {
    guard !isMonitoring else { return }
    isMonitoring = true
    ensureForecastScheduler()
    let generation = forecastGeneration

    if observesWakeEvents {
      let observer = MonitoringWakeObserver()
      observer.start { [weak self] in
        self?.enqueueForecastRefresh(trigger: .recovery)
      }
      wakeObserver = observer
    }

    let prepareNotifications = prepareNotifications
    notificationPreparationTask = Task {
      await prepareNotifications()
    }
    initialRefreshTask = Task { [weak self] in
      await self?.refresh(generation: generation)
    }
  }

  func stopMonitoring() {
    isMonitoring = false
    forecastGeneration &+= 1
    pollingTimerTask?.cancel()
    pollingTimerTask = nil
    initialRefreshTask?.cancel()
    initialRefreshTask = nil
    notificationPreparationTask?.cancel()
    notificationPreparationTask = nil
    wakeObserver?.stop()
    wakeObserver = nil

    forecastSchedulerContinuation?.finish()
    forecastSchedulerContinuation = nil
    forecastSchedulerTask?.cancel()
    forecastSchedulerTask = nil

    resume(&currentRefreshWaiters)
    if var pendingForecastRefresh {
      resume(&pendingForecastRefresh.waiters)
      self.pendingForecastRefresh = nil
    }
    refreshActivityCount = 0
    isRefreshing = false
  }

  func refreshForecast() async {
    await requestForecastRefresh(trigger: .manual, generation: forecastGeneration)
  }

  func monitoringDidRecover() async {
    await requestForecastRefresh(trigger: .recovery, generation: forecastGeneration)
  }

  func refresh() async {
    await refresh(generation: forecastGeneration)
  }

  private func refresh(generation: UInt64) async {
    guard generation == forecastGeneration else { return }
    guard !isRefreshing else { return }
    beginRefreshActivity()
    issues.removeAll { !$0.hasPrefix(forecastIssuePrefix) }
    defer {
      if generation == forecastGeneration {
        endRefreshActivity()
      }
    }

    let scanSessions = scanSessions
    let usageTask = Task.detached(priority: .userInitiated) {
      try scanSessions()
    }

    await requestForecastRefresh(trigger: .manual, generation: generation)
    guard generation == forecastGeneration, !Task.isCancelled else { return }

    switch await usageTask.result {
    case .success(let events):
      tokenEvents = events
    case .failure(let error):
      issues.append(
        String(
          format: AppLocalization.string("Token usage: %@"),
          error.localizedDescription
        )
      )
    }
  }

  private func ensureForecastScheduler() {
    guard forecastSchedulerTask == nil else { return }
    let generation = forecastGeneration
    var continuation: AsyncStream<Void>.Continuation?
    let events = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    forecastSchedulerContinuation = continuation
    forecastSchedulerTask = Task { [weak self] in
      for await _ in events {
        guard !Task.isCancelled else { return }
        await self?.processNextForecastRefresh(generation: generation)
      }
    }
  }

  private func requestForecastRefresh(
    trigger: ForecastRefreshTrigger,
    generation: UInt64
  ) async {
    ensureForecastScheduler()
    await withCheckedContinuation { continuation in
      enqueueForecastRefresh(
        trigger: trigger,
        generation: generation,
        waiter: continuation
      )
    }
  }

  private func enqueueForecastRefresh(
    trigger: ForecastRefreshTrigger,
    generation: UInt64? = nil,
    waiter: CheckedContinuation<Void, Never>? = nil
  ) {
    let generation = generation ?? forecastGeneration
    guard generation == forecastGeneration else {
      waiter?.resume()
      return
    }
    ensureForecastScheduler()
    if trigger != .scheduled {
      pollingTimerTask?.cancel()
      pollingTimerTask = nil
    }

    if trigger == .manual,
      forecastFetchInProgress,
      activeFetchGeneration == generation
    {
      if let waiter {
        currentRefreshWaiters.append(waiter)
      }
      return
    }

    if pendingForecastRefresh != nil {
      pendingForecastRefresh?.merge(trigger: trigger, waiter: waiter)
    } else {
      pendingForecastRefresh = PendingForecastRefresh(
        generation: generation,
        trigger: trigger,
        waiters: waiter.map { [$0] } ?? []
      )
    }
    forecastSchedulerContinuation?.yield()
  }

  private func processNextForecastRefresh(generation: UInt64) async {
    guard generation == forecastGeneration,
      !forecastFetchInProgress,
      let pendingForecastRefresh,
      pendingForecastRefresh.generation == generation
    else {
      return
    }
    self.pendingForecastRefresh = nil
    pollingTimerTask?.cancel()
    pollingTimerTask = nil
    forecastFetchInProgress = true
    activeFetchGeneration = generation
    currentRefreshWaiters = pendingForecastRefresh.waiters
    beginRefreshActivity()

    await loadForecast(generation: generation)

    if activeFetchGeneration == generation {
      forecastFetchInProgress = false
      activeFetchGeneration = nil
    }

    guard generation == forecastGeneration, !Task.isCancelled else {
      if self.pendingForecastRefresh?.generation == forecastGeneration {
        forecastSchedulerContinuation?.yield()
      }
      return
    }

    lastUpdated = .now
    endRefreshActivity()
    resume(&currentRefreshWaiters)

    guard !Task.isCancelled, isMonitoring, self.pendingForecastRefresh == nil else { return }
    scheduleNextPoll(generation: generation)
  }

  private func scheduleNextPoll(generation: UInt64) {
    pollingTimerTask?.cancel()
    let delay = consecutiveForecastFailures == 0
      ? pollingSchedule.successDelay
      : pollingSchedule.failureDelay(consecutiveFailures: consecutiveForecastFailures)
    let sleep = sleep
    pollingTimerTask = Task { @MainActor [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard !Task.isCancelled,
        let self,
        generation == forecastGeneration,
        isMonitoring
      else {
        return
      }
      pollingTimerTask = nil
      enqueueForecastRefresh(trigger: .scheduled, generation: generation)
    }
  }

  private var forecastIssuePrefix: String {
    AppLocalization.string("Reset forecast: %@")
      .replacingOccurrences(of: "%@", with: "")
  }

  private func loadForecast(generation: UInt64) async {
    do {
      let result = try await fetchForecast(forecastETag)
      guard generation == forecastGeneration, !Task.isCancelled else { return }
      switch result {
      case .updated(let updated, let responseETag):
        forecast = updated
        forecastETag = responseETag
        consecutiveForecastFailures = 0
        removeForecastIssue()
        await observeForecast(updated)
      case .notModified:
        consecutiveForecastFailures = 0
        removeForecastIssue()
        await observeForecast(forecast)
      }
    } catch {
      guard generation == forecastGeneration, !Task.isCancelled else { return }
      consecutiveForecastFailures += 1
      setForecastIssue(error: error)
    }
  }

  private func beginRefreshActivity() {
    refreshActivityCount += 1
    isRefreshing = true
  }

  private func endRefreshActivity() {
    refreshActivityCount = max(0, refreshActivityCount - 1)
    isRefreshing = refreshActivityCount > 0
  }

  private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
    let resumed = waiters
    waiters.removeAll()
    for waiter in resumed {
      waiter.resume()
    }
  }

  private func removeForecastIssue() {
    issues.removeAll { $0.hasPrefix(forecastIssuePrefix) }
  }

  private func setForecastIssue(error: Error) {
    removeForecastIssue()
    let message = error as? ResetForecastServiceError == .notInitialized
      ? AppLocalization.string("Reset monitoring is starting up.")
      : AppLocalization.string("Reset monitoring is temporarily unavailable.")
    issues.append(
      String(
        format: AppLocalization.string("Reset forecast: %@"),
        message
      )
    )
  }
}
