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
  func keepsLatestMonthIdentityStableAcrossSameMonthResponses() throws {
    let firstHistory = try decodeHistory(
      resetHistoryJSON(generatedAt: "2026-07-19T09:00:00Z")
    )
    let secondHistory = try decodeHistory(
      resetHistoryJSON(generatedAt: "2026-07-19T10:00:00Z")
    )

    let firstPresentation = ResetHistoryPresentation(
      history: firstHistory,
      selectedRange: .sixMonths,
      locale: Locale(identifier: "en_US")
    )
    let secondPresentation = ResetHistoryPresentation(
      history: secondHistory,
      selectedRange: .sixMonths,
      locale: Locale(identifier: "en_US")
    )

    #expect(firstPresentation.months.last?.id == secondPresentation.months.last?.id)
  }

  @Test
  func allChartScrollsOnAppearanceAndLatestMonthIdentityChanges() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let viewSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexRadar/Views/ResetHistoryView.swift"),
      encoding: .utf8
    )

    #expect(viewSource.contains(".onAppear {"))
    #expect(viewSource.contains(".onChange(of: presentation.months.last?.id)"))
    #expect(!viewSource.contains(".onChange(of: presentation.responseRevision)"))
  }

  @Test
  func formatsLabelsAndRecentRowsInResponseTimeZone() throws {
    let resetAt = "2025-12-31T10:30:00Z"
    let kiritimatiHistory = try decodeHistory(
      resetHistoryJSON(
        range: "all",
        startYear: 2025,
        startMonth: 12,
        monthCount: 2,
        timeZoneIdentifier: "Pacific/Kiritimati",
        generatedAt: "2026-01-01T00:00:00Z",
        recent: """
          {"id":"reset-1","reset_at":"\(resetAt)"}
          """
      )
    )
    let losAngelesHistory = try decodeHistory(
      resetHistoryJSON(
        range: "all",
        startYear: 2025,
        startMonth: 12,
        monthCount: 1,
        timeZoneIdentifier: "America/Los_Angeles",
        generatedAt: "2026-01-01T00:00:00Z",
        recent: """
          {"id":"reset-1","reset_at":"\(resetAt)"}
          """
      )
    )

    let kiritimatiPresentation = ResetHistoryPresentation(
      history: kiritimatiHistory,
      selectedRange: .all,
      locale: Locale(identifier: "en_US")
    )
    let losAngelesPresentation = ResetHistoryPresentation(
      history: losAngelesHistory,
      selectedRange: .all,
      locale: Locale(identifier: "en_US")
    )

    #expect(kiritimatiHistory.recent.first?.resetAt == losAngelesHistory.recent.first?.resetAt)
    #expect(kiritimatiPresentation.months.map(\.label) == ["Dec 25", "Jan 26"])
    #expect(losAngelesPresentation.months.map(\.label) == ["Dec 25"])
    #expect(kiritimatiPresentation.rangeDescription == "Dec 2025 – Jan 2026")
    #expect(losAngelesPresentation.rangeDescription == "Dec 2025 – Dec 2025")
    #expect(
      kiritimatiPresentation.recent.first?.dateTime == "Jan 1, 2026 at 12:30\u{202F}AM"
    )
    #expect(
      losAngelesPresentation.recent.first?.dateTime == "Dec 31, 2025 at 2:30\u{202F}AM"
    )
  }
}

private func decodeHistory(_ json: String) throws -> ResetHistory {
  try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}
