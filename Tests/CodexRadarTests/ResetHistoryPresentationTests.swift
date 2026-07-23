import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryPresentationTests {
  @Test
  func cropsFixedRangeToNewestMonths() throws {
    let history = try decodeHistory(resetHistoryJSON())

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .threeMonths,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.selectedRange == .threeMonths)
    #expect(presentation.months.map(\.id) == ["2026-05", "2026-06", "2026-07"])
    #expect(presentation.months.map(\.label) == ["May", "Jun", "Jul"])
    #expect(presentation.weekCount == 2)
    #expect(presentation.monthCount == 7)
    #expect(presentation.recent.count == 2)
  }

  @Test
  func describesFixedRangeWithYearsAtBothEnds() throws {
    let history = try decodeHistory(resetHistoryJSON())

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .sixMonths,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.rangeDescription == "Feb 2026 – Jul 2026")
  }

  @Test
  func keepsTwelveMonthsAcrossYearBoundary() throws {
    let history = try decodeHistory(
      resetHistoryJSON(
        range: "12m",
        startYear: 2025,
        startMonth: 8,
        monthCount: 12,
        generatedAt: "2026-07-19T09:00:00Z"
      )
    )

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .twelveMonths,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.months.count == 12)
    #expect(presentation.months.first?.id == "2025-08")
    #expect(presentation.months.last?.id == "2026-07")
    #expect(presentation.months.first?.label == "Aug")
    #expect(presentation.months.last?.label == "Jul")
    #expect(presentation.rangeDescription == "Aug 2025 – Jul 2026")
  }

  @Test
  func keepsAllMonthsAndIncludesShortYearsInLabels() throws {
    let history = try decodeHistory(
      resetHistoryJSON(
        range: "all",
        startYear: 2025,
        startMonth: 5,
        monthCount: 15,
        generatedAt: "2026-07-19T09:00:00Z"
      )
    )

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .all,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.months.count == 15)
    #expect(presentation.months.first?.label == "May 25")
    #expect(presentation.months.last?.label == "Jul 26")
    #expect(presentation.rangeDescription == "May 2025 – Jul 2026")
  }

  @Test
  func formatsLabelsAndRecentRowsInResponseTimeZone() throws {
    let history = try decodeHistory(
      resetHistoryJSON(
        range: "all",
        startYear: 2025,
        startMonth: 12,
        monthCount: 2,
        timeZoneIdentifier: "Pacific/Kiritimati",
        generatedAt: "2026-01-01T00:00:00Z",
        recent: """
          {"id":"reset-1","reset_at":"2025-12-31T10:30:00Z"}
          """
      )
    )

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .all,
      locale: Locale(identifier: "en_US")
    )

    #expect(TimeZone.current.identifier != history.timeZone)
    #expect(presentation.months.map(\.label) == ["Dec 25", "Jan 26"])
    #expect(presentation.rangeDescription == "Dec 2025 – Jan 2026")
    #expect(presentation.recent.first?.dateTime == "Jan 1, 2026 at 12:30\u{202F}AM")
  }
}

private func decodeHistory(_ json: String) throws -> ResetHistory {
  try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}
