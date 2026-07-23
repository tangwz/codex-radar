import Foundation
import Testing

@testable import CodexRadar

@Suite(.serialized)
struct ResetHistoryStoreTests {
  @MainActor
  @Test
  func firstDashboardAppearanceRequestsSixMonths() async {
    let context = makeContext()

    context.store.refresh(timeZone: context.zone)
    await settle()
    #expect(await context.fetcher.callCount == 0)

    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)
    await expectCallCount(1, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests
        == [
          HistoryRequest(
            timeZoneIdentifier: context.zone.identifier,
            range: .sixMonths
          )
        ])

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
  }

  @MainActor
  @Test
  func ordinaryIdenticalRequestsCoalesceWithoutTrailingReload() async {
    let context = makeContext()

    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)
    await expectCallCount(1, fetcher: context.fetcher)
    context.store.refresh(timeZone: context.zone)
    context.store.refresh(timeZone: context.zone)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
    await settle()

    #expect(await context.fetcher.callCount == 1)
    context.store.dashboardDidDisappear()
  }

  @MainActor
  @Test
  func coveredSelectionsDoNotRequestMoreData() async {
    let context = makeContext()
    await loadInitialHistory(context)

    context.store.selectRange(.threeMonths, timeZone: context.zone)
    await settle()
    #expect(context.store.selectedRange == .threeMonths)
    #expect(context.store.pendingRange == nil)
    #expect(await context.fetcher.callCount == 1)

    context.store.selectRange(.sixMonths, timeZone: context.zone)
    await settle()
    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.pendingRange == nil)
    #expect(await context.fetcher.callCount == 1)
  }

  @MainActor
  @Test
  func firstTwelveMonthSelectionRequestsTwelveMonths() async {
    let context = makeContext()
    await loadInitialHistory(context)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)

    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.pendingRange == .twelveMonths)
    #expect(await context.fetcher.requests.last?.range == .twelveMonths)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await expectStoreIdle(context.store)

    #expect(context.store.selectedRange == .twelveMonths)
    #expect(context.store.history?.range == .twelveMonths)
  }

  @MainActor
  @Test
  func firstAllSelectionRequestsAll() async {
    let context = makeContext()
    await loadInitialHistory(context)

    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)

    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.pendingRange == .all)
    #expect(await context.fetcher.requests.last?.range == .all)

    await context.fetcher.completeNext(with: .success(history(range: .all)))
    await expectStoreIdle(context.store)

    #expect(context.store.selectedRange == .all)
    #expect(context.store.history?.range == .all)
  }

  @MainActor
  @Test
  func committedAllSnapshotServesEveryLaterSelectionLocally() async {
    let context = makeContext()
    await loadInitialHistory(context)
    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(history(range: .all)))
    await expectStoreIdle(context.store)

    for range in ResetHistoryRange.allCases {
      context.store.selectRange(range, timeZone: context.zone)
      await settle()
      #expect(context.store.selectedRange == range)
      #expect(context.store.pendingRange == nil)
    }

    #expect(await context.fetcher.callCount == 2)
    #expect(context.store.history?.range == .all)
  }

  @MainActor
  @Test
  func failedExpansionKeepsCommittedSnapshotAndSelection() async {
    let context = makeContext()
    await loadInitialHistory(context)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectStoreIdle(context.store)

    #expect(context.store.history?.range == .sixMonths)
    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.pendingRange == nil)
    #expect(context.store.issue == "History unavailable")
  }

  @MainActor
  @Test
  func newerExpansionInvalidatesOlderResponse() async {
    let context = makeContext()
    await loadInitialHistory(context)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await settle()

    #expect(context.store.history?.range == .sixMonths)
    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.pendingRange == .all)

    await context.fetcher.completeNext(with: .success(history(range: .all)))
    await expectStoreIdle(context.store)

    #expect(context.store.history?.range == .all)
    #expect(context.store.selectedRange == .all)
  }

  @MainActor
  @Test
  func refreshCoalescesWithInFlightExpansion() async {
    let context = makeContext()
    await loadInitialHistory(context)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.refresh(timeZone: context.zone)
    await settle()

    #expect(await context.fetcher.callCount == 2)
    #expect(context.store.pendingRange == .twelveMonths)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await expectStoreIdle(context.store)

    #expect(context.store.history?.range == .twelveMonths)
    #expect(context.store.selectedRange == .twelveMonths)
  }

  @MainActor
  @Test
  func refreshUsesCurrentSelectionsNormalizedFetchRange() async {
    let context = makeContext()
    await loadInitialHistory(context)
    context.store.selectRange(.threeMonths, timeZone: context.zone)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)

    #expect(await context.fetcher.requests.last?.range == .sixMonths)
    #expect(context.store.selectedRange == .threeMonths)
    #expect(context.store.pendingRange == nil)

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
    #expect(context.store.selectedRange == .threeMonths)
  }

  @MainActor
  @Test
  func explicitAllRefreshReplacesActiveQueryThatCannotCoverTarget() async throws {
    let context = makeContext()
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let narrowAt = Date(timeIntervalSince1970: 1_700_000_200)
    let refreshedAt = Date(timeIntervalSince1970: 1_700_000_300)
    await loadInitialHistory(context)

    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(
      with: .success(history(range: .all, generatedAt: cachedAt)))
    await expectStoreIdle(context.store)

    context.store.selectRange(.threeMonths, timeZone: context.zone)
    context.store.refresh(timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)
    context.store.selectRange(.all, timeZone: context.zone)

    #expect(context.store.selectedRange == .all)
    #expect(context.store.isLoading)
    #expect(await context.fetcher.requests.last?.range == .sixMonths)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(4, fetcher: context.fetcher)
    try #require(await context.fetcher.callCount == 4)

    #expect(
      await context.fetcher.requests.map(\.range)
        == [.sixMonths, .all, .sixMonths, .all])

    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, generatedAt: narrowAt)))
    await settle()
    #expect(context.store.history?.generatedAt == cachedAt)
    #expect(context.store.isLoading)

    await context.fetcher.completeNext(
      with: .success(history(range: .all, generatedAt: refreshedAt)))
    await expectStoreIdle(context.store)

    #expect(context.store.history?.generatedAt == refreshedAt)
    #expect(context.store.selectedRange == .all)
    #expect(await context.fetcher.callCount == 4)
  }

  @MainActor
  @Test
  func timeZoneChangeUsesCurrentSelectionsNormalizedFetchRange() async {
    let context = makeContext()
    let utc = TimeZone(identifier: "UTC")!
    await loadInitialHistory(context)
    context.store.selectRange(.threeMonths, timeZone: context.zone)

    context.store.refresh(timeZone: utc)
    await expectCallCount(2, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests.last
        == HistoryRequest(timeZoneIdentifier: utc.identifier, range: .sixMonths))

    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, timeZone: utc.identifier)))
    await expectStoreIdle(context.store)
  }

  @MainActor
  @Test
  func failedTimeZoneRequestSchedulesFutureBoundaryInRequestedTimeZone() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let context = makeContext(now: { now })
    let utc = try #require(TimeZone(identifier: "UTC"))
    let expectedBoundary = try #require(
      ResetHistoryRefreshSchedule.nextBoundary(after: now, timeZone: utc))
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.refresh(timeZone: utc)
    await expectCallCount(2, fetcher: context.fetcher)
    await expectCancellationCount(1, waiter: context.waiter)
    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)
    let boundaries = await context.waiter.dates
    try #require(boundaries.count == 2)

    #expect(boundaries[1] == expectedBoundary)
    #expect(boundaries[1] > now)
    #expect(await context.waiter.activeWaitCount == 1)
    #expect(await context.fetcher.callCount == 2)
    #expect(context.store.history?.timeZone == context.zone.identifier)
    #expect(context.store.issue == "History unavailable")

    await context.waiter.fireNext()
    await expectCallCount(3, fetcher: context.fetcher)
    #expect(
      await context.fetcher.requests.last
        == HistoryRequest(timeZoneIdentifier: utc.identifier, range: .sixMonths))

    context.store.dashboardDidDisappear()
    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, timeZone: utc.identifier)))
    await settle()
  }

  @MainActor
  @Test
  func failedReturnToRetainedTimeZoneReplacesForeignBoundaryWait() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let context = makeContext(now: { now })
    let utc = try #require(TimeZone(identifier: "UTC"))
    let expectedUTCBoundary = try #require(
      ResetHistoryRefreshSchedule.nextBoundary(after: now, timeZone: utc))
    let expectedShanghaiBoundary = try #require(
      ResetHistoryRefreshSchedule.nextBoundary(after: now, timeZone: context.zone))
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)
    let retainedGeneratedAt = try #require(context.store.history?.generatedAt)

    context.store.refresh(timeZone: utc)
    await expectCallCount(2, fetcher: context.fetcher)
    await expectCancellationCount(1, waiter: context.waiter)
    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)

    var boundaries = await context.waiter.dates
    try #require(boundaries.count == 2)
    #expect(boundaries[1] == expectedUTCBoundary)
    #expect(await context.waiter.activeWaitCount == 1)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)
    await expectCancellationCount(2, waiter: context.waiter)
    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectStoreIdle(context.store)
    await expectWaitCount(3, waiter: context.waiter)

    boundaries = await context.waiter.dates
    try #require(boundaries.count == 3)
    #expect(boundaries[2] == expectedShanghaiBoundary)
    #expect(await context.waiter.activeWaitCount == 1)
    #expect(await context.fetcher.callCount == 3)
    #expect(context.store.history?.generatedAt == retainedGeneratedAt)
    #expect(context.store.history?.timeZone == context.zone.identifier)
    #expect(context.store.issue == "History unavailable")

    await context.waiter.fireNext()
    await expectCallCount(4, fetcher: context.fetcher)
    #expect(
      await context.fetcher.requests.last
        == HistoryRequest(
          timeZoneIdentifier: context.zone.identifier,
          range: .sixMonths
        ))
    await settle()
    #expect(await context.fetcher.callCount == 4)
    #expect(context.store.history?.generatedAt == retainedGeneratedAt)

    context.store.dashboardDidDisappear()
    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )))
    await settle()
    #expect(context.store.history?.generatedAt == retainedGeneratedAt)
  }

  @MainActor
  @Test
  func coveredSelectionInDifferentTimeZoneRequestsFreshData() async {
    let context = makeContext()
    let utc = TimeZone(identifier: "UTC")!
    await loadInitialHistory(context)

    context.store.selectRange(.threeMonths, timeZone: utc)
    await expectCallCount(2, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests.last
        == HistoryRequest(timeZoneIdentifier: utc.identifier, range: .sixMonths))
    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.pendingRange == .threeMonths)

    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, timeZone: utc.identifier)))
    await expectStoreIdle(context.store)

    #expect(context.store.selectedRange == .threeMonths)
    #expect(context.store.history?.timeZone == utc.identifier)
  }

  @MainActor
  @Test
  func coveredSelectionPreservesInFlightOrdinaryRefresh() async {
    let context = makeContext()
    let refreshedAt = Date(timeIntervalSince1970: 1_700_000_100)
    await loadInitialHistory(context)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.selectRange(.threeMonths, timeZone: context.zone)

    #expect(context.store.selectedRange == .threeMonths)
    #expect(context.store.isLoading)
    #expect(await context.fetcher.callCount == 2)

    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, generatedAt: refreshedAt)))
    await expectStoreIdle(context.store)

    #expect(context.store.history?.generatedAt == refreshedAt)
    #expect(context.store.selectedRange == .threeMonths)
  }

  @MainActor
  @Test
  func resetChangesDuringLoadStartOneTrailingNormalizedReload() async {
    let context = makeContext()
    let initialReset = Date(timeIntervalSince1970: 1_700_000_000)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: initialReset)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
    context.store.selectRange(.threeMonths, timeZone: context.zone)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_100),
      timeZone: context.zone
    )
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_200),
      timeZone: context.zone
    )
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_300),
      timeZone: context.zone
    )

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )))
    await expectCallCount(3, fetcher: context.fetcher)

    #expect(await context.fetcher.requests.map(\.range) == [.sixMonths, .sixMonths, .sixMonths])
    #expect(context.store.selectedRange == .threeMonths)

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )))
    await expectStoreIdle(context.store)
    await settle()

    #expect(await context.fetcher.callCount == 3)
  }

  @MainActor
  @Test
  func resetDuringExpansionTrailsTheExpansionTarget() async {
    let context = makeContext()
    let initialReset = Date(timeIntervalSince1970: 1_700_000_000)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: initialReset)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_100),
      timeZone: context.zone
    )

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await expectCallCount(3, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests.map(\.range)
        == [.sixMonths, .twelveMonths, .twelveMonths])
    #expect(context.store.selectedRange == .twelveMonths)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await expectStoreIdle(context.store)
    context.store.dashboardDidDisappear()
  }

  @MainActor
  @Test
  func resetIntentSurvivesCancelingExpansionForCoveredSelection() async {
    let context = makeContext()
    let initialReset = Date(timeIntervalSince1970: 1_700_000_000)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: initialReset)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_100),
      timeZone: context.zone
    )
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_200),
      timeZone: context.zone
    )
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_300),
      timeZone: context.zone
    )
    context.store.selectRange(.threeMonths, timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests.map(\.range)
        == [.sixMonths, .twelveMonths, .sixMonths])
    #expect(context.store.selectedRange == .threeMonths)
    #expect(context.store.isLoading)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await settle()
    #expect(context.store.history?.range == .sixMonths)

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
    await settle()

    #expect(context.store.selectedRange == .threeMonths)
    #expect(await context.fetcher.callCount == 3)
  }

  @MainActor
  @Test
  func resetIntentTransfersAcrossReplacementWithoutLaterReset() async {
    let context = makeContext()
    let initialReset = Date(timeIntervalSince1970: 1_700_000_000)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: initialReset)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_100),
      timeZone: context.zone
    )
    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)
    context.store.selectRange(.threeMonths, timeZone: context.zone)
    await expectCallCount(4, fetcher: context.fetcher)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await settle()
    await context.fetcher.completeNext(with: .success(history(range: .all)))
    await settle()

    #expect(
      await context.fetcher.requests.map(\.range)
        == [.sixMonths, .twelveMonths, .all, .sixMonths])

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
    await settle()

    #expect(context.store.selectedRange == .threeMonths)
    #expect(await context.fetcher.callCount == 4)
  }

  @MainActor
  @Test
  func freshnessResponseRetargetedBeyondFetchedRangeTrailsCurrentTarget() async {
    let context = makeContext()
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let narrowAt = Date(timeIntervalSince1970: 1_700_000_200)
    let refreshedAt = Date(timeIntervalSince1970: 1_700_000_300)
    await loadInitialHistory(context)

    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(
      with: .success(history(range: .all, generatedAt: cachedAt)))
    await expectStoreIdle(context.store)

    context.store.selectRange(.threeMonths, timeZone: context.zone)
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_150),
      timeZone: context.zone
    )
    await expectCallCount(3, fetcher: context.fetcher)
    context.store.selectRange(.all, timeZone: context.zone)

    #expect(context.store.selectedRange == .all)
    #expect(await context.fetcher.requests.last?.range == .sixMonths)

    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, generatedAt: narrowAt)))
    await expectCallCount(4, fetcher: context.fetcher)

    #expect(context.store.history?.generatedAt == cachedAt)
    #expect(context.store.isLoading)
    #expect(await context.fetcher.requests.last?.range == .all)

    await context.fetcher.completeNext(
      with: .success(history(range: .all, generatedAt: refreshedAt)))
    await expectStoreIdle(context.store)
    await settle()

    #expect(context.store.history?.generatedAt == refreshedAt)
    #expect(context.store.selectedRange == .all)
    #expect(await context.fetcher.callCount == 4)
  }

  @MainActor
  @Test
  func resetFreshnessSurvivesArbitraryReplacementChain() async {
    let context = makeContext()
    let initialReset = Date(timeIntervalSince1970: 1_700_000_000)
    let finalGeneratedAt = Date(timeIntervalSince1970: 1_700_000_500)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: initialReset)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(
      with: .success(
        history(range: .sixMonths, generatedAt: initialReset)
      ))
    await expectStoreIdle(context.store)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.lastResetDidChange(
      Date(timeIntervalSince1970: 1_700_000_100),
      timeZone: context.zone
    )
    context.store.selectRange(.threeMonths, timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)
    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(4, fetcher: context.fetcher)
    context.store.selectRange(.sixMonths, timeZone: context.zone)
    await expectCallCount(5, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests.map(\.range)
        == [.sixMonths, .twelveMonths, .sixMonths, .all, .sixMonths])
    #expect(context.store.selectedRange == .sixMonths)

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .twelveMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )))
    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )))
    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .all,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )))
    await settle()

    #expect(context.store.history?.generatedAt == initialReset)
    #expect(context.store.isLoading)

    await context.fetcher.completeNext(
      with: .success(
        history(range: .sixMonths, generatedAt: finalGeneratedAt)
      ))
    await expectStoreIdle(context.store)
    await settle()

    #expect(context.store.history?.generatedAt == finalGeneratedAt)
    #expect(context.store.selectedRange == .sixMonths)
    #expect(await context.fetcher.callCount == 5)
  }

  @MainActor
  @Test
  func disappearanceCancelsLoadAndBoundaryWaitWithoutDiscardingSnapshot() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.dashboardDidDisappear()
    await expectCancellationCount(1, waiter: context.waiter)

    #expect(!context.store.isLoading)
    #expect(context.store.pendingRange == nil)
    #expect(context.store.history?.range == .sixMonths)
    #expect(context.store.selectedRange == .sixMonths)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await settle()
    #expect(context.store.history?.range == .sixMonths)
    #expect(await context.fetcher.callCount == 2)
  }

  @MainActor
  @Test
  func successfulResponseSchedulesOneBoundaryWait() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    let dates = await context.waiter.dates
    #expect(dates.count == 1)
    #expect(
      dates.first
        == ResetHistoryRefreshSchedule.nextBoundary(
          after: context.store.history!.generatedAt,
          timeZone: context.zone
        ))

    context.store.dashboardDidDisappear()
    await expectCancellationCount(1, waiter: context.waiter)
  }

  @MainActor
  @Test
  func firingBoundaryWhileActiveTriggersOneReload() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    await context.waiter.fireNext()
    await expectCallCount(2, fetcher: context.fetcher)
    await settle()

    #expect(await context.fetcher.callCount == 2)
    #expect(await context.fetcher.requests.last?.range == .sixMonths)

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_604_800)
        )))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)
    context.store.dashboardDidDisappear()
    await expectCancellationCount(1, waiter: context.waiter)
  }

  @MainActor
  @Test
  func failedBoundaryRefreshSchedulesLaterBoundaryWithoutImmediateRetry() async throws {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)
    let firstBoundary = try #require(await context.waiter.dates.first)

    await context.waiter.fireNext()
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)

    let boundaries = await context.waiter.dates
    let laterBoundary = try #require(boundaries.dropFirst().first)
    #expect(laterBoundary > firstBoundary)
    #expect(await context.fetcher.callCount == 2)
    #expect(await context.waiter.activeWaitCount == 1)
    #expect(context.store.issue == "History unavailable")
  }

  @MainActor
  @Test
  func failedTimeZoneReplacementOfBoundaryRequestSchedulesRequestedTimeZone() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let context = makeContext(now: { now })
    let utc = try #require(TimeZone(identifier: "UTC"))
    let expectedBoundary = try #require(
      ResetHistoryRefreshSchedule.nextBoundary(after: now, timeZone: utc))
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    await context.waiter.fireNext()
    await expectCallCount(2, fetcher: context.fetcher)
    context.store.refresh(timeZone: utc)
    await expectCallCount(3, fetcher: context.fetcher)

    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, timeZone: context.zone.identifier)))
    await settle()
    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)

    let boundaries = await context.waiter.dates
    try #require(boundaries.count == 2)
    #expect(boundaries[1] == expectedBoundary)
    #expect(boundaries[1] > now)
    #expect(await context.waiter.activeWaitCount == 1)
    #expect(await context.fetcher.callCount == 3)
    #expect(context.store.history?.timeZone == context.zone.identifier)
    #expect(context.store.issue == "History unavailable")

    await context.waiter.fireNext()
    await expectCallCount(4, fetcher: context.fetcher)
    #expect(
      await context.fetcher.requests.last
        == HistoryRequest(timeZoneIdentifier: utc.identifier, range: .sixMonths))

    context.store.dashboardDidDisappear()
    await context.fetcher.completeNext(
      with: .success(history(range: .sixMonths, timeZone: utc.identifier)))
    await settle()
  }

  @MainActor
  @Test
  func boundaryWaitsForExpansionAndRefreshesExpandedSelection() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.waiter.fireNext()
    await settle()

    #expect(await context.fetcher.callCount == 2)
    #expect(context.store.pendingRange == .twelveMonths)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await expectCallCount(3, fetcher: context.fetcher)

    #expect(await context.fetcher.requests.last?.range == .twelveMonths)
    #expect(context.store.selectedRange == .twelveMonths)

    await context.fetcher.completeNext(with: .success(history(range: .twelveMonths)))
    await expectStoreIdle(context.store)
  }

  @MainActor
  @Test
  func boundaryAfterFailedExpansionRefreshesRetainedSelection() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.waiter.fireNext()
    await settle()

    #expect(await context.fetcher.callCount == 2)
    #expect(context.store.pendingRange == .twelveMonths)

    await context.fetcher.completeNext(with: .failure(.unavailable))
    await expectCallCount(3, fetcher: context.fetcher)

    #expect(await context.fetcher.requests.last?.range == .sixMonths)
    #expect(context.store.selectedRange == .sixMonths)
    #expect(context.store.history?.range == .sixMonths)

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
  }

  @MainActor
  @Test
  func boundaryWaitsForOrdinaryRequestBeforeReloading() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.waiter.fireNext()
    await settle()

    #expect(await context.fetcher.callCount == 2)

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_604_800)
        )))
    await expectCallCount(3, fetcher: context.fetcher)

    #expect(await context.fetcher.requests.last?.range == .sixMonths)

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_604_800)
        )))
    await expectStoreIdle(context.store)
  }

  @MainActor
  @Test
  func boundaryFreshnessSurvivesArbitraryReplacementChain() async {
    let context = makeContext()
    let initialGeneratedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let finalGeneratedAt = Date(timeIntervalSince1970: 1_700_000_500)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(
      with: .success(
        history(range: .sixMonths, generatedAt: initialGeneratedAt)
      ))
    await expectStoreIdle(context.store)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.selectRange(.twelveMonths, timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.waiter.fireNext()
    await settle()
    context.store.selectRange(.threeMonths, timeZone: context.zone)
    await expectCallCount(3, fetcher: context.fetcher)
    context.store.selectRange(.all, timeZone: context.zone)
    await expectCallCount(4, fetcher: context.fetcher)
    context.store.selectRange(.sixMonths, timeZone: context.zone)
    await expectCallCount(5, fetcher: context.fetcher)

    #expect(
      await context.fetcher.requests.map(\.range)
        == [.sixMonths, .twelveMonths, .sixMonths, .all, .sixMonths])
    #expect(context.store.selectedRange == .sixMonths)

    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .twelveMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )))
    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )))
    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .all,
          generatedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )))
    await settle()

    #expect(context.store.history?.generatedAt == initialGeneratedAt)
    #expect(context.store.isLoading)

    await context.fetcher.completeNext(
      with: .success(
        history(range: .sixMonths, generatedAt: finalGeneratedAt)
      ))
    await expectStoreIdle(context.store)
    await settle()

    #expect(context.store.history?.generatedAt == finalGeneratedAt)
    #expect(context.store.selectedRange == .sixMonths)
    #expect(await context.fetcher.callCount == 5)
  }

  @MainActor
  @Test
  func newerSuccessfulResponseReplacesPreviousBoundaryWait() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.refresh(timeZone: context.zone)
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(
      with: .success(
        history(
          range: .sixMonths,
          generatedAt: Date(timeIntervalSince1970: 1_700_086_400)
        )))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)
    await expectCancellationCount(1, waiter: context.waiter)

    #expect(await context.waiter.activeWaitCount == 1)

    await context.waiter.fireNext()
    await expectCallCount(3, fetcher: context.fetcher)
    #expect(await context.fetcher.callCount == 3)

    await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
    await expectStoreIdle(context.store)
    context.store.dashboardDidDisappear()
  }

  @MainActor
  @Test
  func boundaryDoesNotReloadAfterDisappearance() async {
    let context = makeContext()
    await loadInitialHistory(context)
    await expectWaitCount(1, waiter: context.waiter)

    context.store.dashboardDidDisappear()
    await expectCancellationCount(1, waiter: context.waiter)
    await settle()

    #expect(await context.fetcher.callCount == 1)
    #expect(context.store.history?.range == .sixMonths)
  }

  @MainActor
  @Test
  func staleResponseAfterBoundaryDoesNotCreateImmediateReloadLoop() async throws {
    let context = makeContext()
    let staleHistory = history(range: .sixMonths)
    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(staleHistory))
    await expectStoreIdle(context.store)
    await expectWaitCount(1, waiter: context.waiter)

    await context.waiter.fireNext()
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(staleHistory))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)

    let dates = await context.waiter.dates
    #expect(dates.count == 2)
    let laterDate = try #require(dates.dropFirst().first)
    #expect(laterDate > dates[0])
    #expect(await context.fetcher.callCount == 2)
  }

  @MainActor
  @Test
  func responseCrossingMonthBoundaryCatchesUpOnceThenAdvances() async throws {
    let generatedAt = try #require(
      ISO8601DateFormatter().date(from: "2026-07-31T15:59:59Z"))
    let missedBoundary = try #require(
      ISO8601DateFormatter().date(from: "2026-07-31T16:00:01Z"))
    let commitNow = try #require(
      ISO8601DateFormatter().date(from: "2026-07-31T16:00:02Z"))
    let context = makeContext(now: { commitNow })
    let staleHistory = history(range: .sixMonths, generatedAt: generatedAt)

    context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)
    await expectCallCount(1, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(staleHistory))
    await expectStoreIdle(context.store)
    await expectWaitCount(1, waiter: context.waiter)

    #expect(await context.waiter.dates == [missedBoundary])

    await context.waiter.fireNext()
    await expectCallCount(2, fetcher: context.fetcher)
    await context.fetcher.completeNext(with: .success(staleHistory))
    await expectStoreIdle(context.store)
    await expectWaitCount(2, waiter: context.waiter)

    let boundaries = await context.waiter.dates
    let futureBoundary = try #require(boundaries.dropFirst().first)
    #expect(futureBoundary > commitNow)
    #expect(futureBoundary > missedBoundary)
    #expect(await context.fetcher.callCount == 2)
  }
}

@MainActor
private struct HistoryStoreTestContext {
  let fetcher: ControlledHistoryFetcher
  let waiter: ControlledHistoryWaiter
  let store: ResetHistoryStore
  let zone: TimeZone
}

@MainActor
private func makeContext(
  now: @escaping ResetHistoryStore.Now = {
    Date(timeIntervalSince1970: 1_700_000_000)
  }
) -> HistoryStoreTestContext {
  let fetcher = ControlledHistoryFetcher()
  let waiter = ControlledHistoryWaiter()
  let store = ResetHistoryStore(
    fetchHistory: {
      try await fetcher.fetch(timeZoneIdentifier: $0, range: $1)
    },
    waitUntil: {
      try await waiter.wait(until: $0)
    },
    now: now,
    formatIssue: { "History unavailable" }
  )
  return HistoryStoreTestContext(
    fetcher: fetcher,
    waiter: waiter,
    store: store,
    zone: TimeZone(identifier: "Asia/Shanghai")!
  )
}

@MainActor
private func loadInitialHistory(_ context: HistoryStoreTestContext) async {
  context.store.dashboardDidAppear(timeZone: context.zone, lastResetAt: nil)
  await expectCallCount(1, fetcher: context.fetcher)
  await context.fetcher.completeNext(with: .success(history(range: .sixMonths)))
  await expectStoreIdle(context.store)
}

@MainActor
private func expectStoreIdle(_ store: ResetHistoryStore) async {
  for _ in 0..<1_000 {
    if !store.isLoading {
      return
    }
    await Task.yield()
  }
  Issue.record("Timed out waiting for store completion.")
}

private func expectCallCount(_ count: Int, fetcher: ControlledHistoryFetcher) async {
  await eventually("Timed out waiting for history request count \(count).") {
    await fetcher.callCount >= count
  }
}

private func expectWaitCount(_ count: Int, waiter: ControlledHistoryWaiter) async {
  await eventually("Timed out waiting for boundary wait count \(count).") {
    await waiter.dates.count >= count
  }
}

private func expectCancellationCount(_ count: Int, waiter: ControlledHistoryWaiter) async {
  await eventually("Timed out waiting for boundary cancellation count \(count).") {
    await waiter.cancellationCount >= count
  }
}

private func eventually(
  _ message: String,
  condition: () async -> Bool
) async {
  for _ in 0..<1_000 {
    if await condition() {
      return
    }
    await Task.yield()
  }
  Issue.record(Comment(rawValue: message))
}

private func settle() async {
  for _ in 0..<20 {
    await Task.yield()
  }
}

private struct HistoryRequest: Equatable, Sendable {
  let timeZoneIdentifier: String
  let range: ResetHistoryRange
}

private actor ControlledHistoryFetcher {
  enum Outcome: Sendable {
    case success(ResetHistory)
    case failure(ResetHistoryServiceError)
  }

  private var continuations: [CheckedContinuation<Outcome, Never>] = []
  private(set) var requests: [HistoryRequest] = []

  var callCount: Int { requests.count }

  func fetch(
    timeZoneIdentifier: String,
    range: ResetHistoryRange
  ) async throws -> ResetHistory {
    requests.append(
      HistoryRequest(timeZoneIdentifier: timeZoneIdentifier, range: range))
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

private actor ControlledHistoryWaiter {
  private struct Wait {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var waits: [Wait] = []
  private(set) var dates: [Date] = []
  private(set) var cancellationCount = 0

  var activeWaitCount: Int { waits.count }

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

  func fireNext() {
    guard !waits.isEmpty else {
      Issue.record("No pending boundary wait to fire.")
      return
    }
    waits.removeFirst().continuation.resume()
  }

  private func cancel(id: UUID) {
    guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
    cancellationCount += 1
    waits.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

private func history(
  range: ResetHistoryRange,
  timeZone: String = "Asia/Shanghai",
  generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ResetHistory {
  let formatter = ISO8601DateFormatter()
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZone)!
  let generatedMonth = calendar.dateInterval(of: .month, for: generatedAt)!.start
  let monthCount: Int
  switch range {
  case .threeMonths:
    monthCount = 3
  case .sixMonths:
    monthCount = 6
  case .twelveMonths:
    monthCount = 12
  case .all:
    monthCount = 19
  }
  let start = calendar.date(byAdding: .month, value: -(monthCount - 1), to: generatedMonth)!
  return try! APIJSONCoding.makeDecoder().decode(
    ResetHistory.self,
    from: Data(
      resetHistoryJSON(
        range: range.rawValue,
        startYear: calendar.component(.year, from: start),
        startMonth: calendar.component(.month, from: start),
        monthCount: monthCount,
        timeZoneIdentifier: timeZone,
        generatedAt: formatter.string(from: generatedAt)
      ).utf8
    )
  )
}
