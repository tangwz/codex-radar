import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryPresentationTests {
  @Test
  func mapsStatisticsAndRecentRows() throws {
    let presentation = ResetHistoryPresentation(
      history: try presentationHistory(year: 2026, recentCount: 5),
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.year == 2026)
    #expect(presentation.weekCount == 2)
    #expect(presentation.monthCount == 6)
    #expect(presentation.months.count == 12)
    #expect(presentation.months.first?.label == "Jan")
    #expect(presentation.months.last?.label == "Dec")
    #expect(presentation.recent.count == 5)
    #expect(presentation.recent.first?.dateTime == "Jul 19, 2026 at 4:21\u{202F}AM")
    #expect(presentation.availableYears == [2026, 2025])
  }

  @Test
  func formatsCommittedSnapshotInItsResponseTimeZone() throws {
    let liveRequestTimeZone = TimeZone(identifier: "America/Los_Angeles")!
    let history = try presentationHistory(
      year: 2026,
      recentCount: 1,
      januaryFrom: "2025-12-31T16:00:00Z",
      recentAt: "2025-12-31T16:30:00Z"
    )
    let presentation = ResetHistoryPresentation(
      history: history,
      locale: Locale(identifier: "en_US")
    )

    #expect(liveRequestTimeZone.identifier != history.timeZone)
    #expect(presentation.months.first?.label == "Jan")
    #expect(presentation.recent.first?.dateTime == "Jan 1, 2026 at 12:30\u{202F}AM")
  }

  @Test
  func includesCommittedYearInUniqueDescendingPickerOptions() throws {
    let history = try presentationHistory(
      year: 2025,
      recentCount: 0,
      availableYears: [2026, 2024, 2024]
    )
    let originalAvailableYears = history.availableYears

    let presentation = ResetHistoryPresentation(
      history: history,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.year == 2025)
    #expect(presentation.availableYears == [2026, 2025, 2024])
    #expect(history.availableYears == originalAvailableYears)
  }
}

private func presentationHistory(
  year: Int,
  recentCount: Int,
  januaryFrom: String? = nil,
  availableYears: [Int] = [2026, 2025],
  recentAt: String = "2026-07-18T20:21:34Z"
) throws -> ResetHistory {
  let months = (1...12).map { month in
    resetHistoryMonthSummaryJSON(
      year: year,
      month: month,
      timeZoneIdentifier: "Asia/Shanghai",
      from: month == 1 ? januaryFrom : nil
    )
  }.joined(separator: ",")
  let years = availableYears.map(String.init).joined(separator: ",")
  let recent = (0..<recentCount).map { offset in
    let index = offset + 1
    return """
      {"id":"reset-\(index)","reset_at":"\(recentAt)"}
      """
  }.joined(separator: ",")
  let json = """
    {
      "schema_version":"1.0",
      "generated_at":"2026-07-19T09:00:00Z",
      "time_zone":"Asia/Shanghai",
      "year":\(year),
      "available_years":[\(years)],
      "current":{
        "week":{"from":"2026-07-13T16:00:00Z","to":"2026-07-20T16:00:00Z","count":2},
        "month":{"from":"2026-06-30T16:00:00Z","to":"2026-07-31T16:00:00Z","count":6}
      },
      "months":[\(months)],
      "recent":[\(recent)]
    }
    """

  return try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}
