import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryStoreTests {
  @MainActor
  @Test
  func doesNotLoadUntilDashboardAppears() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    store.refresh(timeZone: zone)
    await Task.yield()
    #expect(await fetcher.callCount == 0)

    store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
    await waitForCallCount(1, fetcher: fetcher)

    #expect(await fetcher.callCount == 1)
    #expect(
      await fetcher.requests == [HistoryRequest(timeZoneIdentifier: zone.identifier, year: 2026)])

    await fetcher.completeNext(with: .success(history(year: 2026)))
    await waitUntil { store.history?.year == 2026 && !store.isLoading }
  }

  @MainActor
  @Test
  func failedYearSelectionKeepsCommittedData() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
    await waitForCallCount(1, fetcher: fetcher)
    await fetcher.completeNext(with: .success(history(year: 2026)))
    await waitUntil { store.history?.year == 2026 && !store.isLoading }

    store.selectYear(2025, timeZone: zone)
    await waitForCallCount(2, fetcher: fetcher)
    #expect(store.pendingYear == 2025)
    #expect(store.isLoading)

    await fetcher.completeNext(with: .failure(.unavailable))
    await waitUntil { !store.isLoading }

    #expect(store.history?.year == 2026)
    #expect(store.pendingYear == nil)
    #expect(store.issue == "History unavailable")
  }

  @MainActor
  @Test
  func newerYearRequestWinsAndClearsObsoleteTrailingReload() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
    await waitForCallCount(1, fetcher: fetcher)
    await fetcher.completeNext(
      with: .success(history(year: 2026, availableYears: [2026, 2025, 2024])))
    await waitUntil { store.history?.year == 2026 && !store.isLoading }

    store.selectYear(2025, timeZone: zone)
    await waitForCallCount(2, fetcher: fetcher)
    store.selectYear(2025, timeZone: zone)
    store.selectYear(2024, timeZone: zone)
    await waitForCallCount(3, fetcher: fetcher)

    await fetcher.completeNext(
      with: .success(history(year: 2025, availableYears: [2026, 2025, 2024])))
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(store.history?.year == 2026)
    #expect(store.pendingYear == 2024)
    #expect(await fetcher.callCount == 3)

    await fetcher.completeNext(
      with: .success(history(year: 2024, availableYears: [2026, 2025, 2024])))
    await waitUntil { store.history?.year == 2024 && !store.isLoading }

    #expect(store.pendingYear == nil)
    #expect(!store.isLoading)
    #expect(await fetcher.callCount == 3)
  }

  @MainActor
  @Test
  func changedLastResetReloadsOnlyWhileDashboardIsActive() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let firstReset = Date(timeIntervalSince1970: 1_700_000_000)
    let secondReset = Date(timeIntervalSince1970: 1_700_000_100)
    let thirdReset = Date(timeIntervalSince1970: 1_700_000_200)

    store.lastResetDidChange(firstReset, timeZone: zone)
    await Task.yield()
    #expect(await fetcher.callCount == 0)

    store.dashboardDidAppear(timeZone: zone, lastResetAt: firstReset)
    await waitForCallCount(1, fetcher: fetcher)
    await fetcher.completeNext(with: .success(history(year: 2026)))
    await waitUntil { store.history?.year == 2026 && !store.isLoading }

    store.lastResetDidChange(secondReset, timeZone: zone)
    await waitForCallCount(2, fetcher: fetcher)
    await fetcher.completeNext(with: .success(history(year: 2026)))
    await waitUntil { !store.isLoading }

    store.dashboardDidDisappear()
    store.lastResetDidChange(thirdReset, timeZone: zone)
    await Task.yield()

    #expect(await fetcher.callCount == 2)
  }

  @MainActor
  @Test
  func disappearanceCancelsAndBlocksTheInFlightCommit() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
    await waitForCallCount(1, fetcher: fetcher)
    #expect(store.isLoading)

    store.dashboardDidDisappear()
    #expect(!store.isLoading)
    #expect(store.pendingYear == nil)

    await fetcher.completeNext(with: .success(history(year: 2026)))
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(store.history == nil)
    #expect(store.issue == nil)
    #expect(await fetcher.callCount == 1)
  }

  @MainActor
  @Test
  func changedTimeZoneReloadsTheCommittedYear() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    let utc = TimeZone(identifier: "UTC")!

    store.dashboardDidAppear(timeZone: shanghai, lastResetAt: nil)
    await waitForCallCount(1, fetcher: fetcher)
    await fetcher.completeNext(with: .success(history(year: 2025, timeZone: shanghai.identifier)))
    await waitUntil { store.history?.year == 2025 && !store.isLoading }

    store.refresh(timeZone: utc)
    await waitForCallCount(2, fetcher: fetcher)

    #expect(
      await fetcher.requests.last
        == HistoryRequest(timeZoneIdentifier: utc.identifier, year: 2025))

    await fetcher.completeNext(with: .success(history(year: 2025, timeZone: utc.identifier)))
    await waitUntil { store.history?.timeZone == utc.identifier && !store.isLoading }
  }

  @MainActor
  @Test
  func rejectsASelectedYearThatIsNotAvailable() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    store.dashboardDidAppear(timeZone: zone, lastResetAt: nil)
    await waitForCallCount(1, fetcher: fetcher)
    await fetcher.completeNext(
      with: .success(history(year: 2026, availableYears: [2026, 2025])))
    await waitUntil { store.history?.year == 2026 && !store.isLoading }

    store.selectYear(2024, timeZone: zone)
    await Task.yield()

    #expect(await fetcher.callCount == 1)
    #expect(store.pendingYear == nil)
    #expect(!store.isLoading)
  }

  @MainActor
  @Test
  func resetChangeDuringInitialLoadStartsExactlyOneTrailingReload() async {
    let fetcher = ControlledHistoryFetcher()
    let store = makeHistoryStore(fetcher: fetcher)
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let initialReset = Date(timeIntervalSince1970: 1_700_000_000)
    let changedReset = Date(timeIntervalSince1970: 1_700_000_100)
    let oldGeneratedAt = Date(timeIntervalSince1970: 1_700_000_010)
    let newGeneratedAt = Date(timeIntervalSince1970: 1_700_000_110)

    store.dashboardDidAppear(timeZone: zone, lastResetAt: initialReset)
    await waitForCallCount(1, fetcher: fetcher)

    store.lastResetDidChange(changedReset, timeZone: zone)
    store.lastResetDidChange(changedReset, timeZone: zone)
    await fetcher.completeNext(
      with: .success(history(year: 2026, generatedAt: oldGeneratedAt)))
    await waitForCallCount(2, fetcher: fetcher)

    #expect(store.history?.generatedAt == oldGeneratedAt)
    #expect(store.isLoading)
    #expect(await fetcher.callCount == 2)

    await fetcher.completeNext(
      with: .success(history(year: 2026, generatedAt: newGeneratedAt)))
    await waitUntil { store.history?.generatedAt == newGeneratedAt && !store.isLoading }
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(await fetcher.callCount == 2)
  }
}

@MainActor
private func makeHistoryStore(fetcher: ControlledHistoryFetcher) -> ResetHistoryStore {
  ResetHistoryStore(
    fetchHistory: { try await fetcher.fetch(timeZoneIdentifier: $0, year: $1) },
    formatIssue: { "History unavailable" }
  )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0..<200 {
    if condition() {
      return
    }
    try? await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("Timed out waiting for store state.")
}

private func waitForCallCount(_ count: Int, fetcher: ControlledHistoryFetcher) async {
  for _ in 0..<200 {
    if await fetcher.callCount >= count {
      return
    }
    try? await Task.sleep(for: .milliseconds(1))
  }
  Issue.record("Timed out waiting for history request count \(count).")
}

private struct HistoryRequest: Equatable, Sendable {
  let timeZoneIdentifier: String
  let year: Int?
}

private actor ControlledHistoryFetcher {
  enum Outcome: Sendable {
    case success(ResetHistory)
    case failure(ResetHistoryServiceError)
  }

  private var continuations: [CheckedContinuation<Outcome, Never>] = []
  private(set) var requests: [HistoryRequest] = []

  var callCount: Int { requests.count }

  func fetch(timeZoneIdentifier: String, year: Int?) async throws -> ResetHistory {
    requests.append(HistoryRequest(timeZoneIdentifier: timeZoneIdentifier, year: year))
    let outcome = await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    switch outcome {
    case .success(let history):
      return history
    case .failure(let error):
      throw error
    }
  }

  func completeNext(with outcome: Outcome) {
    guard !continuations.isEmpty else {
      Issue.record("No pending history request to complete.")
      return
    }
    continuations.removeFirst().resume(returning: outcome)
  }
}

private func history(
  year: Int,
  timeZone: String = "Asia/Shanghai",
  availableYears: [Int] = [2026, 2025],
  generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ResetHistory {
  let months = (1...12).map { month in
    let identifier = String(format: "%04d-%02d", year, month)
    return """
      {"month":"\(identifier)","from":"\(year)-01-01T00:00:00Z","to":"\(year)-02-01T00:00:00Z","count":\(month)}
      """
  }.joined(separator: ",")
  let years = availableYears.map(String.init).joined(separator: ",")
  let generatedAtValue = ISO8601DateFormatter().string(from: generatedAt)
  let json = """
    {
      "schema_version":"1.0",
      "generated_at":"\(generatedAtValue)",
      "time_zone":"\(timeZone)",
      "year":\(year),
      "available_years":[\(years)],
      "current":{
        "week":{"from":"\(year)-07-13T16:00:00Z","to":"\(year)-07-20T16:00:00Z","count":2},
        "month":{"from":"\(year)-06-30T16:00:00Z","to":"\(year)-07-31T16:00:00Z","count":6}
      },
      "months":[\(months)],
      "recent":[]
    }
    """
  return try! APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}
