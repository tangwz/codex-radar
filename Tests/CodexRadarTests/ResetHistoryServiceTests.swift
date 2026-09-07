import Foundation
import Testing
@testable import CodexRadar

struct ResetHistoryServiceTests {
  @Test
  func fetchesAllPagesAndAggregatesRegularAndBankedLocally() async throws {
    let recorder = PublicAPIRequests()
    let service = ResetHistoryService(loader: HTTPDataLoader { request in
      await recorder.record(request)
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(query.contains(URLQueryItem(name: "limit", value: "100")))
      #expect(!query.contains { $0.name == "time_zone" || $0.name == "range" })
      if query.contains(where: { $0.name == "cursor" }) {
        return (publicPage(records: [publicRecord(id: "second", kind: "regular")]), publicResponse(request))
      }
      return (publicPage(records: [publicRecord()], more: true, cursor: "page_2"), publicResponse(request))
    }, now: { publicAPINow })
    let history = try await service.fetch(timeZoneIdentifier: "Asia/Singapore", range: .sixMonths)
    #expect(service.historyURL == CodexResetsAPI.historyURL)
    #expect(history.months.count == 6)
    #expect(history.current.week.count == 2)
    #expect(history.current.month.counts.hard == 1)
    #expect(history.current.month.counts.banked == 1)
    #expect(history.current.month.counts.both == 0)
    #expect(history.radarDays?.count == 30)
    #expect(history.recent.count == 2)
    let totals = ResetHistoryPresentation(history: history, selectedRange: .sixMonths, metric: .both, locale: Locale(identifier: "en"))
    #expect(totals.monthCount == 2)
    #expect(ResetRadarPresentation(history: history, locale: Locale(identifier: "en"), now: publicAPINow)?.days.last?.kind == .hardAndBanked)
    #expect(await recorder.requests.count == 2)
  }

  @Test
  func repeatedOrMissingCursorFailsInsteadOfReturningPartialStatistics() async {
    for cursor in ["loop", nil] as [String?] {
      let service = ResetHistoryService(loader: HTTPDataLoader { request in
        (publicPage(records: [publicRecord()], more: true, cursor: cursor), publicResponse(request))
      })
      await #expect(throws: ResetHistoryServiceError.invalidResponse) {
        try await service.fetch(timeZoneIdentifier: "UTC", range: .all)
      }
    }
  }

  @Test
  func laterPageFailureDoesNotCommitPartialHistory() async {
    let service = ResetHistoryService(loader: HTTPDataLoader { request in
      if request.url!.query!.contains("cursor=") { return (Data(), publicResponse(request, status: 503)) }
      return (publicPage(records: [publicRecord()], more: true, cursor: "next"), publicResponse(request))
    })
    await #expect(throws: ResetHistoryServiceError.unavailable) {
      try await service.fetch(timeZoneIdentifier: "UTC", range: .sixMonths)
    }
  }

  @Test
  func deduplicatesIdenticalOpaqueIDsAcrossPages() async throws {
    let service = ResetHistoryService(loader: HTTPDataLoader { request in
      let last = request.url!.query!.contains("cursor=")
      return (publicPage(records: [publicRecord()], more: !last, cursor: last ? nil : "next"), publicResponse(request))
    }, now: { publicAPINow })
    let history = try await service.fetch(timeZoneIdentifier: "UTC", range: .all)
    #expect(history.current.month.count == 1)
    #expect(history.recent.first?.id == "observed-a")
  }

  @Test
  func usesNaturalLocalMonthAndMondayWeekBoundaries() async throws {
    let service = ResetHistoryService(loader: HTTPDataLoader { request in
      (publicPage(records: [
        publicRecord(id: "previous", at: "2026-08-31T15:59:59Z"),
        publicRecord(id: "current", kind: "regular", at: "2026-08-31T16:00:00Z"),
        publicRecord(id: "sunday", at: "2026-09-06T15:59:59Z"),
        publicRecord(id: "monday", at: "2026-09-06T16:00:00Z"),
      ]), publicResponse(request))
    }, now: { publicAPINow })
    let history = try await service.fetch(timeZoneIdentifier: "Asia/Singapore", range: .twelveMonths)
    #expect(history.months.count == 12)
    #expect(history.current.month.count == 3)
    #expect(history.current.week.count == 1)
  }

  @Test
  func representsDSTDaysAsNaturalDaysNot86400Seconds() async throws {
    let date = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z")!
    let service = ResetHistoryService(loader: HTTPDataLoader { request in
      (publicPage(), publicResponse(request))
    }, now: { date })
    let history = try await service.fetch(timeZoneIdentifier: "America/Los_Angeles", range: .all)
    let dst = try #require(history.radarDays?.first { $0.day == "2026-03-08" })
    #expect(dst.to.timeIntervalSince(dst.from) == 23 * 3600)
  }

  @Test
  func rejectsInvalidTimeZoneBeforeLoading() async {
    let service = ResetHistoryService(loader: HTTPDataLoader { _ in
      Issue.record("Invalid zone must not call network")
      throw URLError(.badURL)
    })
    await #expect(throws: ResetHistoryServiceError.invalidRequest) {
      try await service.fetch(timeZoneIdentifier: "Invalid/Zone", range: .sixMonths)
    }
  }
}
