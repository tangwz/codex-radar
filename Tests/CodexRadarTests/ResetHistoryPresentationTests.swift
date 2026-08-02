import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryPresentationTests {
  @Test
  func ordersMetricsForDashboardSelection() {
    #expect(ResetHistoryMetric.allCases == [.both, .hard, .banked])
  }

  @Test(
    arguments: [
      (metric: ResetHistoryMetric.both, week: 2, month: 2, months: [2, 2, 2]),
      (metric: ResetHistoryMetric.hard, week: 2, month: 7, months: [5, 6, 7]),
      (metric: ResetHistoryMetric.banked, week: 3, month: 3, months: [3, 3, 3]),
    ])
  func projectsCountsForSelectedMetric(
    metric: ResetHistoryMetric,
    week: Int,
    month: Int,
    months: [Int]
  ) throws {
    let history = try decodeHistory(resetHistoryJSON())

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .threeMonths,
      metric: metric,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.metric == metric)
    #expect(presentation.weekCount == week)
    #expect(presentation.monthCount == month)
    #expect(presentation.months.map(\.count) == months)
  }

  @Test
  func cropsFixedRangeToNewestMonths() throws {
    let history = try decodeHistory(resetHistoryJSON())

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .threeMonths,
      metric: .hard,
      locale: Locale(identifier: "en_US")
    )

    #expect(presentation.selectedRange == .threeMonths)
    #expect(presentation.months.map(\.id) == ["2026-05", "2026-06", "2026-07"])
    #expect(presentation.months.map(\.label) == ["May", "Jun", "Jul"])
    #expect(presentation.weekCount == 2)
    #expect(presentation.monthCount == 7)
  }

  @Test
  func describesFixedRangeWithYearsAtBothEnds() throws {
    let history = try decodeHistory(resetHistoryJSON())

    let presentation = ResetHistoryPresentation(
      history: history,
      selectedRange: .sixMonths,
      metric: .hard,
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
      metric: .hard,
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
      metric: .hard,
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
      metric: .hard,
      locale: Locale(identifier: "en_US")
    )
    let secondPresentation = ResetHistoryPresentation(
      history: secondHistory,
      selectedRange: .sixMonths,
      metric: .hard,
      locale: Locale(identifier: "en_US")
    )

    #expect(firstPresentation.months.last?.id == secondPresentation.months.last?.id)
  }

  @Test
  func allChartScrollsOnAppearanceAndLatestMonthIdentityChanges() throws {
    let viewSource = try resetHistoryViewSource()

    #expect(viewSource.contains(".onAppear {"))
    #expect(viewSource.contains(".onChange(of: presentation.months.last?.id)"))
    #expect(!viewSource.contains(".onChange(of: presentation.responseRevision)"))
  }

  @Test
  func resetMetricSelectionIsViewLocalAndDefaultsToBoth() throws {
    let viewSource = try resetHistoryViewSource()

    #expect(
      viewSource.contains(
        "@State private var selectedMetric: ResetHistoryMetric = .both"))
    #expect(viewSource.contains("Picker(\"Reset type\", selection: $selectedMetric)"))
    #expect(viewSource.contains("metric: selectedMetric"))

    let bothTag = try #require(viewSource.range(of: ".tag(ResetHistoryMetric.both)"))
    let hardTag = try #require(viewSource.range(of: ".tag(ResetHistoryMetric.hard)"))
    let bankedTag = try #require(viewSource.range(of: ".tag(ResetHistoryMetric.banked)"))
    #expect(bothTag.lowerBound < hardTag.lowerBound)
    #expect(hardTag.lowerBound < bankedTag.lowerBound)
  }

  @Test
  func resetChartUsesMetricSpecificTitlesWithoutRecentDetails() throws {
    let viewSource = try resetHistoryViewSource()

    #expect(viewSource.contains("Hard + banked resets by month"))
    #expect(viewSource.contains("Hard resets by month"))
    #expect(viewSource.contains("Banked resets by month"))
    #expect(!viewSource.contains("recentList("))
    #expect(!viewSource.contains("Text(\"Recent resets\")"))
    #expect(!viewSource.contains("Text(\"Latest 5\")"))
    #expect(!viewSource.contains("Text(month.count, format: .number)"))
  }

  @Test
  func resetChartHoverResolvesStableMonthIDsAndClearsOnExit() throws {
    let viewSource = try resetHistoryViewSource()

    #expect(viewSource.contains("x: .value(\"Month\", month.id)"))
    #expect(viewSource.contains(".chartXAxis"))
    #expect(viewSource.contains("AxisMarks(values: months.map(\\.id))"))
    #expect(viewSource.contains("RuleMark("))
    #expect(viewSource.contains(".chartOverlay"))
    #expect(viewSource.contains(".onContinuousHover"))
    #expect(viewSource.contains("chartProxy.value(atX: plotX)"))
    #expect(viewSource.contains("hoveredMonthID = nil"))
    #expect(viewSource.contains("monthAccessibilityLabel"))
  }

  @Test
  func formatsLabelsInResponseTimeZone() throws {
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
      metric: .hard,
      locale: Locale(identifier: "en_US")
    )
    let losAngelesPresentation = ResetHistoryPresentation(
      history: losAngelesHistory,
      selectedRange: .all,
      metric: .hard,
      locale: Locale(identifier: "en_US")
    )

    #expect(kiritimatiPresentation.months.map(\.label) == ["Dec 25", "Jan 26"])
    #expect(losAngelesPresentation.months.map(\.label) == ["Dec 25"])
    #expect(kiritimatiPresentation.rangeDescription == "Dec 2025 – Jan 2026")
    #expect(losAngelesPresentation.rangeDescription == "Dec 2025 – Dec 2025")
  }
}

private func decodeHistory(_ json: String) throws -> ResetHistory {
  try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}

private func resetHistoryViewSource() throws -> String {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try String(
    contentsOf: repositoryRoot.appendingPathComponent(
      "Sources/CodexRadar/Views/ResetHistoryView.swift"),
    encoding: .utf8
  )
}
