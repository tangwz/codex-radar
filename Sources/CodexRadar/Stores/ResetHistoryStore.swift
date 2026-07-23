import Combine
import Foundation

@MainActor
final class ResetHistoryStore: ObservableObject {
  typealias FetchHistory =
    @Sendable (String, ResetHistoryRange) async throws -> ResetHistory
  typealias WaitUntil = @Sendable (Date) async throws -> Void

  @Published private(set) var history: ResetHistory?
  @Published private(set) var selectedRange: ResetHistoryRange = .sixMonths
  @Published private(set) var pendingRange: ResetHistoryRange?
  @Published private(set) var isLoading = false
  @Published private(set) var issue: String?

  private let fetchHistory: FetchHistory
  private let waitUntil: WaitUntil
  private let formatIssue: @MainActor @Sendable () -> String
  private var isDashboardActive = false
  private var lastObservedResetAt: Date?
  private var activeQuery: Query?
  private var needsTrailingResetReload = false
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
  }

  init(
    service: ResetHistoryService = ResetHistoryService(),
    waitUntil: @escaping WaitUntil = { date in
      let duration = max(0, date.timeIntervalSinceNow)
      try await Task.sleep(for: .seconds(duration))
    },
    formatIssue: @escaping @MainActor @Sendable () -> String = {
      AppLocalization.string("Reset history is temporarily unavailable.")
    }
  ) {
    fetchHistory = {
      try await service.fetch(timeZoneIdentifier: $0, range: $1)
    }
    self.waitUntil = waitUntil
    self.formatIssue = formatIssue
  }

  init(
    fetchHistory: @escaping FetchHistory,
    waitUntil: @escaping WaitUntil = { date in
      let duration = max(0, date.timeIntervalSinceNow)
      try await Task.sleep(for: .seconds(duration))
    },
    formatIssue: @escaping @MainActor @Sendable () -> String = {
      AppLocalization.string("Reset history is temporarily unavailable.")
    }
  ) {
    self.fetchHistory = fetchHistory
    self.waitUntil = waitUntil
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
    needsTrailingResetReload = false
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
      cancelExpansionRequestIfNeeded()
      retargetOrdinaryRequestIfNeeded(to: range)
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
      if case .resetChange = trigger {
        needsTrailingResetReload = true
      }
      return
    }

    cancelBoundaryRefreshIfTimeZoneChanged(to: query.timeZoneIdentifier)
    needsTrailingResetReload = false
    generation &+= 1
    let requestGeneration = generation
    loadTask?.cancel()
    activeQuery = query
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
        self.finish()
      } catch is CancellationError {
        guard let self, requestGeneration == self.generation else { return }
        self.finish()
      } catch {
        guard
          !Task.isCancelled,
          let self,
          requestGeneration == self.generation
        else { return }
        self.issue = self.formatIssue()
        self.finish()
      }
    }
  }

  private func finish() {
    guard let completedQuery = activeQuery else { return }
    let shouldReload = needsTrailingResetReload && isDashboardActive
    let trailingQuery = Query(
      timeZoneIdentifier: completedQuery.timeZoneIdentifier,
      fetchRange: completedQuery.targetRange.requestedRange,
      targetRange: completedQuery.targetRange
    )
    self.activeQuery = nil
    needsTrailingResetReload = false
    pendingRange = nil
    isLoading = false
    loadTask = nil

    guard shouldReload else { return }
    request(trailingQuery, trigger: .ordinary)
  }

  private func cancelExpansionRequestIfNeeded() {
    guard
      let activeQuery,
      history?.timeZone != activeQuery.timeZoneIdentifier
        || history?.range.covers(activeQuery.targetRange) != true
    else { return }
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    self.activeQuery = nil
    needsTrailingResetReload = false
    pendingRange = nil
    isLoading = false
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
    guard
      isDashboardActive,
      let timeZone = TimeZone(identifier: history.timeZone),
      let boundary = ResetHistoryRefreshSchedule.nextBoundary(
        after: history.generatedAt,
        timeZone: timeZone
      ),
      lastTriggeredBoundary.map({ boundary > $0 }) ?? true
    else { return }
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
    request(
      Query(
        timeZoneIdentifier: timeZone.identifier,
        fetchRange: selectedRange.requestedRange,
        targetRange: selectedRange
      ),
      trigger: .ordinary
    )
  }
}
