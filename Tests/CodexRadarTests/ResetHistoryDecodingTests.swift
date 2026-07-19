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
  monthCount: Int = 12,
  recentCount: Int = 2,
  timeZone: String = "Asia/Shanghai",
  weekCount: Int = 2,
  months: String? = nil,
  recent: String? = nil
) -> String {
  let resolvedMonths =
    months
    ?? (1...monthCount).map { month in
      let value = String(format: "2026-%02d", month)
      return """
        {"month":"\(value)","from":"2026-01-01T00:00:00Z","to":"2026-02-01T00:00:00Z","count":\(month)}
        """
    }.joined(separator: ",")
  let resolvedRecent =
    recent
    ?? (1...recentCount).map { index in
      """
      {"id":"reset-\(index)","reset_at":"2026-07-19T08:21:34Z"}
      """
    }.joined(separator: ",")
  return """
    {
      "schema_version":"1.0",
      "generated_at":"2026-07-19T09:00:00Z",
      "time_zone":"\(timeZone)",
      "year":2026,
      "available_years":[2026,2025],
      "current":{
        "week":{"from":"2026-07-13T16:00:00Z","to":"2026-07-20T16:00:00Z","count":\(weekCount)},
        "month":{"from":"2026-06-30T16:00:00Z","to":"2026-07-31T16:00:00Z","count":6}
      },
      "months":[\(resolvedMonths)],
      "recent":[\(resolvedRecent)]
    }
    """
}

private func invalidIntervalMonths() -> String {
  let months = (1...12).map { month -> String in
    let value = String(format: "2026-%02d", month)
    let to = month == 1 ? "2026-01-01T00:00:00Z" : "2026-02-01T00:00:00Z"
    return """
      {"month":"\(value)","from":"2026-01-01T00:00:00Z","to":"\(to)","count":\(month)}
      """
  }
  return months.joined(separator: ",")
}

private func duplicateMonthIDs() -> String {
  let months = (1...12).map { month in
    let value = month == 12 ? "2026-11" : String(format: "2026-%02d", month)
    return """
      {"month":"\(value)","from":"2026-01-01T00:00:00Z","to":"2026-02-01T00:00:00Z","count":\(month)}
      """
  }
  return months.joined(separator: ",")
}

private func duplicateRecentIDs() -> String {
  """
  {"id":"reset-1","reset_at":"2026-07-19T08:21:34Z"},
  {"id":"reset-1","reset_at":"2026-07-19T09:21:34Z"}
  """
}
