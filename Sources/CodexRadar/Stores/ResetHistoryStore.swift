import Combine
import Foundation

@MainActor
final class ResetHistoryStore: ObservableObject {
  typealias FetchHistory =
    @Sendable (String, ResetHistoryRange) async throws -> ResetHistory
  typealias WaitUntil = @Sendable (Date) async throws -> Void
  typealias Now = @Sendable () -> Date

  @Published private(set) var history: ResetHistory?
  @Published private(set) var selectedRange: ResetHistoryRange = .sixMonths
  @Published private(set) var pendingRange: ResetHistoryRange?
  @Published private(set) var isLoading = false
  @Published private(set) var issue: String?

  private let fetchHistory: FetchHistory
  private let waitUntil: WaitUntil
  private let now: Now
  private let formatIssue: @MainActor @Sendable () -> String
  private var isDashboardActive = false
  private var lastObservedResetAt: Date?
  private var activeQuery: Query?
  private var carriedFreshness: FreshnessIntent = []
  private var pendingFreshness: FreshnessIntent = []
  private var loadTask: Task<Void, Never>?
  private var boundaryTask: Task<Void, Never>?
  private var lastTriggeredBoundary: Date?
  private var generation: UInt64 = 0

  private struct Query: Equatable, Sendable {
    let timeZoneIdentifier: String
    let fetchRange: ResetHistoryRange
    let targetRange: ResetHistoryRange
  }

  private enum RequestTrigger {
    case ordinary
    case resetChange
    case boundary
  }

  private struct FreshnessIntent: OptionSet, Sendable {
    let rawValue: UInt8

    static let reset = FreshnessIntent(rawValue: 1 << 0)
    static let boundary = FreshnessIntent(rawValue: 1 << 1)
  }

  init(
    service: ResetHistoryService = ResetHistoryService(),
    waitUntil: @escaping WaitUntil = { date in
      let duration = max(0, date.timeIntervalSinceNow)
      try await Task.sleep(for: .seconds(duration))
    },
    now: @escaping Now = Date.init,
    formatIssue: @escaping @MainActor @Sendable () -> String = {
      AppLocalization.string("Reset history is temporarily unavailable.")
    }
  ) {
    fetchHistory = {
      try await service.fetch(timeZoneIdentifier: $0, range: $1)
    }
    self.waitUntil = waitUntil
    self.now = now
    self.formatIssue = formatIssue
  }

  init(
    fetchHistory: @escaping FetchHistory,
    waitUntil: @escaping WaitUntil = { date in
      let duration = max(0, date.timeIntervalSinceNow)
      try await Task.sleep(for: .seconds(duration))
    },
    now: @escaping Now = Date.init,
    formatIssue: @escaping @MainActor @Sendable () -> String = {
      AppLocalization.string("Reset history is temporarily unavailable.")
    }
  ) {
    self.fetchHistory = fetchHistory
    self.waitUntil = waitUntil
    self.now = now
    self.formatIssue = formatIssue
  }

  func dashboardDidAppear(timeZone: TimeZone, lastResetAt: Date?) {
    isDashboardActive = true
    lastObservedResetAt = lastResetAt
    request(
      Query(
        timeZoneIdentifier: timeZone.identifier,
        fetchRange: selectedRange.requestedRange,
        targetRange: selectedRange
      ),
      trigger: .ordinary
    )
  }

  func dashboardDidDisappear() {
    isDashboardActive = false
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    boundaryTask?.cancel()
    boundaryTask = nil
    activeQuery = nil
    carriedFreshness = []
    pendingFreshness = []
    pendingRange = nil
    isLoading = false
  }

  func refresh(timeZone: TimeZone) {
    guard isDashboardActive else { return }
    let query: Query
    if let activeQuery, activeQuery.timeZoneIdentifier == timeZone.identifier {
      query = activeQuery
    } else {
      query = Query(
        timeZoneIdentifier: timeZone.identifier,
        fetchRange: selectedRange.requestedRange,
        targetRange: selectedRange
      )
    }
    request(query, trigger: .ordinary)
  }

  func selectRange(_ range: ResetHistoryRange, timeZone: TimeZone) {
    guard isDashboardActive else { return }
    if history?.timeZone == timeZone.identifier,
      history?.range.covers(range) == true
    {
      let canceledExpansion = cancelExpansionRequestIfNeeded()
      retargetOrdinaryRequestIfNeeded(to: range)
      selectedRange = range
      pendingRange = nil
      if canceledExpansion {
        reloadAfterCanceledRequestIfNeeded(timeZone: timeZone)
      }
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

  func lastResetDidChange(_ resetAt: Date?, timeZone: TimeZone) {
    guard resetAt != lastObservedResetAt else { return }
    lastObservedResetAt = resetAt
    guard isDashboardActive else { return }
    let query =
      activeQuery
      ?? Query(
        timeZoneIdentifier: timeZone.identifier,
        fetchRange: selectedRange.requestedRange,
        targetRange: selectedRange
      )
    request(query, trigger: .resetChange)
  }

  private func request(_ query: Query, trigger: RequestTrigger) {
    if activeQuery == query {
      switch trigger {
      case .ordinary:
        break
      case .resetChange:
        pendingFreshness.insert(.reset)
      case .boundary:
        pendingFreshness.insert(.boundary)
      }
      return
    }

    cancelBoundaryRefreshIfTimeZoneChanged(to: query.timeZoneIdentifier)
    var transferredFreshness = carriedFreshness.union(pendingFreshness)
    switch trigger {
    case .ordinary:
      break
    case .resetChange:
      transferredFreshness.insert(.reset)
    case .boundary:
      transferredFreshness.insert(.boundary)
    }
    generation &+= 1
    let requestGeneration = generation
    loadTask?.cancel()
    activeQuery = query
    carriedFreshness = transferredFreshness
    pendingFreshness = []
    pendingRange =
      history?.timeZone == query.timeZoneIdentifier
        && history?.range.covers(query.targetRange) == true
      ? nil
      : query.targetRange
    isLoading = true
    let fetchHistory = fetchHistory

    loadTask = Task { [weak self] in
      do {
        let result = try await fetchHistory(query.timeZoneIdentifier, query.fetchRange)
        guard
          !Task.isCancelled,
          let self,
          requestGeneration == self.generation
        else { return }
        guard let activeQuery = self.activeQuery else { return }
        if result.range.covers(activeQuery.targetRange) {
          self.history = result
          self.selectedRange = activeQuery.targetRange
          self.issue = nil
          self.scheduleBoundaryRefresh(after: result)
        }
        self.finish(consumingCarriedFreshness: true)
      } catch is CancellationError {
        guard let self, requestGeneration == self.generation else { return }
        self.finish(
          consumingCarriedFreshness: false,
          startsTrailingReload: false
        )
      } catch {
        guard
          !Task.isCancelled,
          let self,
          requestGeneration == self.generation
        else { return }
        self.issue = self.formatIssue()
        self.finish(consumingCarriedFreshness: true)
      }
    }
  }

  private func finish(
    consumingCarriedFreshness: Bool,
    startsTrailingReload: Bool = true
  ) {
    guard let completedQuery = activeQuery else { return }
    if !consumingCarriedFreshness {
      pendingFreshness.formUnion(carriedFreshness)
    }
    carriedFreshness = []
    let shouldReloadForReset = pendingFreshness.contains(.reset)
    let shouldReloadAtBoundary = pendingFreshness.contains(.boundary)
    let shouldReload =
      (shouldReloadForReset || shouldReloadAtBoundary)
      && isDashboardActive
      && startsTrailingReload
    let targetRange =
      shouldReloadForReset
      ? completedQuery.targetRange
      : selectedRange
    let trailingQuery = Query(
      timeZoneIdentifier: completedQuery.timeZoneIdentifier,
      fetchRange: targetRange.requestedRange,
      targetRange: targetRange
    )
    self.activeQuery = nil
    pendingRange = nil
    isLoading = false
    loadTask = nil

    guard shouldReload else { return }
    request(trailingQuery, trigger: .ordinary)
  }

  private func cancelExpansionRequestIfNeeded() -> Bool {
    guard
      let activeQuery,
      history?.timeZone != activeQuery.timeZoneIdentifier
        || history?.range.covers(activeQuery.targetRange) != true
    else { return false }
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    pendingFreshness.formUnion(carriedFreshness)
    carriedFreshness = []
    self.activeQuery = nil
    pendingRange = nil
    isLoading = false
    return true
  }

  private func reloadAfterCanceledRequestIfNeeded(timeZone: TimeZone) {
    guard !pendingFreshness.isEmpty else { return }
    request(
      Query(
        timeZoneIdentifier: timeZone.identifier,
        fetchRange: selectedRange.requestedRange,
        targetRange: selectedRange
      ),
      trigger: .ordinary
    )
  }

  private func retargetOrdinaryRequestIfNeeded(to range: ResetHistoryRange) {
    guard let activeQuery else { return }
    self.activeQuery = Query(
      timeZoneIdentifier: activeQuery.timeZoneIdentifier,
      fetchRange: activeQuery.fetchRange,
      targetRange: range
    )
  }

  private func cancelBoundaryRefreshIfTimeZoneChanged(to timeZoneIdentifier: String) {
    guard history?.timeZone != timeZoneIdentifier else { return }
    boundaryTask?.cancel()
    boundaryTask = nil
    lastTriggeredBoundary = nil
  }

  private func scheduleBoundaryRefresh(after history: ResetHistory) {
    boundaryTask?.cancel()
    boundaryTask = nil
    let schedulingAnchor = max(
      history.generatedAt,
      max(lastTriggeredBoundary ?? history.generatedAt, now())
    )
    guard
      isDashboardActive,
      let timeZone = TimeZone(identifier: history.timeZone),
      let boundary = ResetHistoryRefreshSchedule.nextBoundary(
        after: schedulingAnchor,
        timeZone: timeZone
      )
    else { return }
    scheduleBoundaryWait(until: boundary, timeZone: timeZone)
  }

  private func scheduleBoundaryWait(until boundary: Date, timeZone: TimeZone) {
    let waitUntil = waitUntil
    boundaryTask = Task { [weak self] in
      do {
        try await waitUntil(boundary)
        guard !Task.isCancelled, let self else { return }
        self.refreshAtBoundary(boundary, timeZone: timeZone)
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  private func refreshAtBoundary(_ boundary: Date, timeZone: TimeZone) {
    guard isDashboardActive else { return }
    boundaryTask = nil
    lastTriggeredBoundary = boundary
    if activeQuery != nil {
      pendingFreshness.insert(.boundary)
      return
    }
    request(
      Query(
        timeZoneIdentifier: timeZone.identifier,
        fetchRange: selectedRange.requestedRange,
        targetRange: selectedRange
      ),
      trigger: .boundary
    )
  }
}
