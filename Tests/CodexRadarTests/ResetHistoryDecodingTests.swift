import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryDecodingTests {
  @Test
  func decodesTwelveMonthsAndFiveOrFewerRecentEvents() throws {
    let history = try APIJSONCoding.makeDecoder().decode(
      ResetHistory.self,
      from: Data(historyJSON(monthCount: 12, recentCount: 5).utf8)
    )

    #expect(history.year == 2026)
    #expect(history.availableYears == [2026, 2025])
    #expect(history.current.week.count == 2)
    #expect(history.current.month.count == 6)
    #expect(history.months.count == 12)
    #expect(history.recent.count == 5)
  }

  @Test
  func rejectsInvalidCollectionShapes() {
    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(
        ResetHistory.self,
        from: Data(historyJSON(monthCount: 11, recentCount: 2).utf8)
      )
    }
    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(
        ResetHistory.self,
        from: Data(historyJSON(monthCount: 12, recentCount: 6).utf8)
      )
    }
  }

  @Test
  func rejectsCorrectMonthIDsWithRepeatedJanuaryIntervals() {
    let january = resetHistoryMonthInterval(
      year: 2026,
      month: 1,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    let months = (1...12).map { month in
      resetHistoryMonthSummaryJSON(
        year: 2026,
        month: month,
        timeZoneIdentifier: "Asia/Shanghai",
        from: january.from,
        to: january.to
      )
    }.joined(separator: ",")

    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(
        ResetHistory.self,
        from: Data(historyJSON(months: months).utf8)
      )
    }
  }

  @Test
  func rejectsFixedOffsetBoundariesAcrossDaylightSavingTime() {
    let months = (1...12).map { month in
      resetHistoryMonthSummaryJSON(
        year: 2026,
        month: month,
        timeZoneIdentifier: "America/New_York",
        from: month == 4 ? "2026-04-01T05:00:00Z" : nil,
        to: month == 4 ? "2026-05-01T05:00:00Z" : nil
      )
    }.joined(separator: ",")

    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(
        ResetHistory.self,
        from: Data(historyJSON(timeZone: "America/New_York", months: months).utf8)
      )
    }
  }

  @Test
  func rejectsMaximumYearWithoutOverflowing() {
    let months = (1...12).map { month in
      let legacyIdentifier = String(format: "%04d-%02d", Int.max, month)
      return resetHistoryMonthSummaryJSON(
        year: 1,
        month: month,
        timeZoneIdentifier: "UTC",
        identifier: legacyIdentifier
      )
    }.joined(separator: ",")

    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(
        ResetHistory.self,
        from: Data(historyJSON(year: Int.max, timeZone: "UTC", months: months).utf8)
      )
    }
  }

  @Test
  func decodesFourDigitMonthIdentifiersForLowYears() throws {
    let history = try APIJSONCoding.makeDecoder().decode(
      ResetHistory.self,
      from: Data(historyJSON(year: 1, timeZone: "UTC").utf8)
    )

    #expect(history.year == 1)
    #expect(history.months.first?.month == "0001-01")
  }

  @Test(arguments: [
    historyJSON(
      weekFrom: "2026-07-13T16:00:00Z",
      weekTo: "2026-07-20T16:00:00Z"
    ),
    historyJSON(
      monthFrom: "2026-06-29T16:00:00Z",
      monthTo: "2026-07-30T16:00:00Z"
    ),
  ])
  func rejectsCurrentIntervalsOutsideGeneratedAtNaturalBuckets(_ json: String) {
    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: [
    """
    {"id":"reset-1","reset_at":"2026-07-19T08:21:34Z"},
    {"id":"reset-2","reset_at":"2026-07-19T09:21:34Z"}
    """,
    """
    {"id":"reset-1","reset_at":"2026-07-19T09:21:34Z"},
    {"id":"reset-2","reset_at":"2026-07-19T09:21:34Z"}
    """,
  ])
  func rejectsRecentEventsOutsideStableDescendingOrder(_ recent: String) {
    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(
        ResetHistory.self,
        from: Data(historyJSON(recent: recent).utf8)
      )
    }
  }

  @Test(arguments: [
    historyJSON(timeZone: "Invalid/Zone"),
    historyJSON(weekCount: -1),
    historyJSON(months: invalidIntervalMonths()),
    historyJSON(months: duplicateMonthIDs()),
    historyJSON(recent: duplicateRecentIDs()),
  ])
  func rejectsInvalidValues(_ json: String) {
    #expect(throws: DecodingError.self) {
      try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
    }
  }
}

private func historyJSON(
  year: Int = 2026,
  monthCount: Int = 12,
  recentCount: Int = 2,
  timeZone: String = "Asia/Shanghai",
  weekCount: Int = 2,
  weekFrom: String? = nil,
  weekTo: String? = nil,
  monthFrom: String? = nil,
  monthTo: String? = nil,
  months: String? = nil,
  recent: String? = nil
) -> String {
  let boundaryTimeZone = TimeZone(identifier: timeZone) == nil ? "UTC" : timeZone
  let generatedAt = ISO8601DateFormatter().date(from: "2026-07-19T09:00:00Z")!
  let current = resetHistoryCurrentIntervals(
    generatedAt: generatedAt,
    timeZoneIdentifier: boundaryTimeZone
  )
  let resolvedMonths =
    months
    ?? resetHistoryMonthSummariesJSON(
      year: year,
      timeZoneIdentifier: boundaryTimeZone,
      monthCount: monthCount
    )
  let resolvedRecent =
    recent
    ?? (1...recentCount).reversed().map { index in
      """
      {"id":"reset-\(index)","reset_at":"2026-07-19T08:21:34Z"}
      """
    }.joined(separator: ",")
  return """
    {
      "schema_version":"1.0",
      "generated_at":"2026-07-19T09:00:00Z",
      "time_zone":"\(timeZone)",
      "year":\(year),
      "available_years":[2026,2025],
      "current":{
        "week":{"from":"\(weekFrom ?? current.weekFrom)","to":"\(weekTo ?? current.weekTo)","count":\(weekCount)},
        "month":{"from":"\(monthFrom ?? current.monthFrom)","to":"\(monthTo ?? current.monthTo)","count":6}
      },
      "months":[\(resolvedMonths)],
      "recent":[\(resolvedRecent)]
    }
    """
}

private func invalidIntervalMonths() -> String {
  (1...12).map { month -> String in
    let interval = resetHistoryMonthInterval(
      year: 2026,
      month: month,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    return resetHistoryMonthSummaryJSON(
      year: 2026,
      month: month,
      timeZoneIdentifier: "Asia/Shanghai",
      to: month == 1 ? interval.from : interval.to
    )
  }
  .joined(separator: ",")
}

private func duplicateMonthIDs() -> String {
  (1...12).map { month in
    resetHistoryMonthSummaryJSON(
      year: 2026,
      month: month,
      timeZoneIdentifier: "Asia/Shanghai",
      identifier: month == 12 ? "2026-11" : nil
    )
  }
  .joined(separator: ",")
}

private func duplicateRecentIDs() -> String {
  """
  {"id":"reset-1","reset_at":"2026-07-19T08:21:34Z"},
  {"id":"reset-1","reset_at":"2026-07-19T09:21:34Z"}
  """
}
