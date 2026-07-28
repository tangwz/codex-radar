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
  typealias WaitUntilTokenUsageBoundary = @Sendable (Date) async throws -> Void
  typealias Now = @Sendable () -> Date

  @Published private(set) var forecast = ResetForecast.placeholder
  @Published private(set) var tokenUsageSnapshot: TokenUsageSnapshot?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var issues: [String] = []

  private(set) var forecastETag: String?
  private(set) var consecutiveForecastFailures = 0

  var isInitialForecastLoad: Bool {
    isRefreshing && lastUpdated == nil
  }

  private let loadCachedTokenUsage: @Sendable (TimeZone) async -> TokenUsageSnapshot?
  private let refreshTokenUsageSource: @Sendable (TimeZone) async -> TokenUsageRepositoryResult
  private let formatTokenUsageIssue: @MainActor @Sendable (TokenUsageRepositoryIssue) -> String
  private let fetchForecast: @Sendable (String?) async throws -> ResetForecastFetchResult
  private let prepareNotifications: @MainActor @Sendable () async -> Void
  private let observeForecast: @MainActor @Sendable (ResetForecast) async -> Void
  private let formatForecastIssue: @MainActor @Sendable (String?) -> String
  private let pollingSchedule: ResetPollingSchedule
  private let sleep: @Sendable (Duration) async throws -> Void
  private let waitUntilTokenUsageBoundary: WaitUntilTokenUsageBoundary
  private let now: Now
  private let observesWakeEvents: Bool

  private var isMonitoring = false
  private var forecastSchedulerTask: Task<Void, Never>?
  private var forecastSchedulerContinuation: AsyncStream<Void>.Continuation?
  private var pollingTimerTask: Task<Void, Never>?
  private var notificationPreparationTask: Task<Void, Never>?
  private var initialRefreshTask: Task<Void, Never>?
  private var tokenUsageBoundaryTask: Task<Void, Never>?
  private var tokenUsageBoundaryIdentity: UUID?
  private var tokenUsageBoundaryDate: Date?
  private var tokenUsageBoundaryTimeZoneIdentifier: String?
  private var tokenUsageTimeZone: TimeZone?
  private var wakeObserver: MonitoringWakeObserver?
  private var pendingForecastRefresh: PendingForecastRefresh?
  private var forecastFetchInProgress = false
  private var currentRefreshWaiters: [CheckedContinuation<Void, Never>] = []
  private var refreshActivityCount = 0
  private var forecastGeneration: UInt64 = 0
  private var tokenUsageGeneration: UInt64 = 0
  private var activeFetchGeneration: UInt64?
  private var forecastIssue: String?
  private var tokenUsageIssues: [String] = []

  init(
    forecastService: ResetForecastService = ResetForecastService(),
    notificationService: ResetNotificationService = ResetNotificationService()
  ) {
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
    fetchForecast = { try await forecastService.fetch(etag: $0) }
    prepareNotifications = { await notificationService.prepare() }
    observeForecast = { await notificationService.observe($0) }
    formatForecastIssue = { message in
      String(
        format: AppLocalization.string("Reset forecast: %@"),
        message ?? ""
      )
    }
    pollingSchedule = ResetPollingSchedule { Int.random(in: -10...10) }
    sleep = { try await Task.sleep(for: $0) }
    waitUntilTokenUsageBoundary = { date in
      let duration = max(0, date.timeIntervalSinceNow)
      try await Task.sleep(for: .seconds(duration))
    }
    now = Date.init
    observesWakeEvents = true
  }

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
    waitUntilTokenUsageBoundary:
      @escaping WaitUntilTokenUsageBoundary = { date in
        let duration = max(0, date.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(duration))
      },
    now: @escaping Now = Date.init,
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
    self.waitUntilTokenUsageBoundary = waitUntilTokenUsageBoundary
    self.now = now
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
        Task { @MainActor [weak self] in
          await self?.monitoringDidRecover()
        }
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
    tokenUsageGeneration &+= 1
    cancelTokenUsageBoundary()
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
    guard isMonitoring else { return }
    let timeZone = tokenUsageTimeZone ?? TimeZone.autoupdatingCurrent
    async let tokenUsageRefresh: Void = refreshTokenUsage(timeZone: timeZone)
    await requestForecastRefresh(trigger: .recovery, generation: forecastGeneration)
    await tokenUsageRefresh
  }

  func refresh() async {
    await refresh(generation: forecastGeneration)
  }

  func refreshTokenUsage(timeZone: TimeZone) async {
    tokenUsageTimeZone = timeZone
    scheduleTokenUsageBoundary(timeZone: timeZone)
    tokenUsageGeneration &+= 1
    let generation = tokenUsageGeneration
    let result = await refreshTokenUsageSource(timeZone)
    guard generation == tokenUsageGeneration, !Task.isCancelled else { return }
    applyTokenUsage(result, timeZone: timeZone)
  }

  private func refresh(generation: UInt64) async {
    guard generation == forecastGeneration else { return }
    guard !isRefreshing else { return }
    beginRefreshActivity()
    rebuildIssues()
    defer {
      if generation == forecastGeneration {
        endRefreshActivity()
      }
    }

    let timeZone = TimeZone.autoupdatingCurrent
    tokenUsageTimeZone = timeZone
    scheduleTokenUsageBoundary(timeZone: timeZone)
    tokenUsageGeneration &+= 1
    let tokenGeneration = tokenUsageGeneration

    if tokenUsageSnapshot == nil,
      let cached = await loadCachedTokenUsage(timeZone),
      generation == forecastGeneration,
      tokenGeneration == tokenUsageGeneration,
      !Task.isCancelled
    {
      publishTokenUsageSnapshot(cached, timeZone: timeZone)
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
    applyTokenUsage(result, timeZone: timeZone)
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
    let delay =
      consecutiveForecastFailures == 0
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

  private func applyTokenUsage(
    _ result: TokenUsageRepositoryResult,
    timeZone: TimeZone
  ) {
    if let snapshot = result.snapshot {
      publishTokenUsageSnapshot(snapshot, timeZone: timeZone)
    }
    tokenUsageIssues = result.issues.map(formatTokenUsageIssue)
    rebuildIssues()
  }

  private func publishTokenUsageSnapshot(
    _ snapshot: TokenUsageSnapshot,
    timeZone: TimeZone
  ) {
    tokenUsageSnapshot = snapshot
    scheduleTokenUsageBoundary(timeZone: timeZone)
  }

  private func scheduleTokenUsageBoundary(timeZone: TimeZone) {
    tokenUsageTimeZone = timeZone
    guard isMonitoring else { return }

    let current = now()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let boundary = calendar.dateInterval(of: .day, for: current)?.end else {
      return
    }

    if tokenUsageBoundaryTask != nil,
      tokenUsageBoundaryDate == boundary,
      tokenUsageBoundaryTimeZoneIdentifier == timeZone.identifier
    {
      return
    }

    cancelTokenUsageBoundary()
    let waitUntilTokenUsageBoundary = waitUntilTokenUsageBoundary
    let identity = UUID()
    tokenUsageBoundaryIdentity = identity
    tokenUsageBoundaryDate = boundary
    tokenUsageBoundaryTimeZoneIdentifier = timeZone.identifier
    tokenUsageTimeZone = timeZone
    tokenUsageBoundaryTask = Task { @MainActor [weak self] in
      do {
        try await waitUntilTokenUsageBoundary(boundary)
      } catch {
        self?.clearTokenUsageBoundary(ifOwnedBy: identity)
        return
      }
      guard !Task.isCancelled,
        let self,
        tokenUsageBoundaryIdentity == identity,
        isMonitoring
      else {
        return
      }
      clearTokenUsageBoundary(ifOwnedBy: identity)
      await refreshTokenUsage(timeZone: timeZone)
    }
  }

  private func cancelTokenUsageBoundary() {
    let task = tokenUsageBoundaryTask
    tokenUsageBoundaryTask = nil
    tokenUsageBoundaryIdentity = nil
    tokenUsageBoundaryDate = nil
    tokenUsageBoundaryTimeZoneIdentifier = nil
    task?.cancel()
  }

  private func clearTokenUsageBoundary(ifOwnedBy identity: UUID) {
    guard tokenUsageBoundaryIdentity == identity else { return }
    tokenUsageBoundaryTask = nil
    tokenUsageBoundaryIdentity = nil
    tokenUsageBoundaryDate = nil
    tokenUsageBoundaryTimeZoneIdentifier = nil
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
    let message =
      error as? ResetForecastServiceError == .notInitialized
      ? AppLocalization.string("Reset monitoring is starting up.")
      : AppLocalization.string("Reset monitoring is temporarily unavailable.")
    forecastIssue = formatForecastIssue(message)
    rebuildIssues()
  }
}
