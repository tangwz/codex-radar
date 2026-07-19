import Combine
import Foundation

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
  private var needsTrailingResetReload = false
  private var loadTask: Task<Void, Never>?
  private var generation: UInt64 = 0

  private struct Query: Equatable, Sendable {
    let timeZoneIdentifier: String
    let year: Int
  }

  private enum RequestTrigger {
    case ordinary
    case resetChange
  }

  init(
    service: ResetHistoryService = ResetHistoryService(),
    formatIssue: @escaping @MainActor @Sendable () -> String = {
      AppLocalization.string("Reset history is temporarily unavailable.")
    }
  ) {
    fetchHistory = {
      try await service.fetch(timeZoneIdentifier: $0, year: $1)
    }
    self.formatIssue = formatIssue
  }

  init(
    fetchHistory: @escaping FetchHistory,
    formatIssue: @escaping @MainActor @Sendable () -> String = {
      AppLocalization.string("Reset history is temporarily unavailable.")
    }
  ) {
    self.fetchHistory = fetchHistory
    self.formatIssue = formatIssue
  }

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
    needsTrailingResetReload = false
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
    let query =
      activeQuery
      ?? Query(
        timeZoneIdentifier: timeZone.identifier,
        year: history?.year ?? Self.currentYear(in: timeZone)
      )
    request(query, trigger: .resetChange)
  }

  private static func currentYear(in timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.year, from: .now)
  }

  private func request(year: Int, timeZone: TimeZone) {
    let query = Query(timeZoneIdentifier: timeZone.identifier, year: year)
    request(query, trigger: .ordinary)
  }

  private func request(_ query: Query, trigger: RequestTrigger) {
    if activeQuery == query {
      if case .resetChange = trigger {
        needsTrailingResetReload = true
      }
      return
    }

    needsTrailingResetReload = false
    generation &+= 1
    let requestGeneration = generation
    loadTask?.cancel()
    activeQuery = query
    pendingYear = history?.year == query.year ? nil : query.year
    isLoading = true
    let fetchHistory = fetchHistory

    loadTask = Task { [weak self] in
      do {
        let result = try await fetchHistory(query.timeZoneIdentifier, query.year)
        guard
          !Task.isCancelled,
          let self,
          requestGeneration == self.generation
        else { return }
        self.history = result
        self.issue = nil
        self.finish(query)
      } catch is CancellationError {
        guard let self, requestGeneration == self.generation else { return }
        self.finish(query)
      } catch {
        guard
          !Task.isCancelled,
          let self,
          requestGeneration == self.generation
        else { return }
        self.issue = self.formatIssue()
        self.finish(query)
      }
    }
  }

  private func finish(_ query: Query) {
    guard activeQuery == query else { return }

    let shouldReload = needsTrailingResetReload && isDashboardActive
    activeQuery = nil
    needsTrailingResetReload = false
    pendingYear = nil
    isLoading = false
    loadTask = nil

    guard shouldReload else { return }
    request(query, trigger: .ordinary)
  }
}
