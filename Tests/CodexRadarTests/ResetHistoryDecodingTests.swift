import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryDecodingTests {
  @Test
  func decodesSixMonthRangeEndingInGeneratedAtMonth() throws {
    let history = try decodeHistory(resetHistoryJSON())

    #expect(history.schemaVersion == "1.0")
    #expect(history.range == .sixMonths)
    #expect(
      history.months.map(\.month) == [
        "2026-02", "2026-03", "2026-04",
        "2026-05", "2026-06", "2026-07",
      ])
    #expect(history.current.month.count == history.months.last?.count)
  }

  @Test(arguments: ["3m", "12m", "all"])
  func decodesOtherValidRanges(_ range: String) throws {
    let json: String
    switch range {
    case "3m":
      json = resetHistoryJSON(range: range, startYear: 2026, startMonth: 5, monthCount: 3)
    case "12m":
      json = resetHistoryJSON(range: range, startYear: 2025, startMonth: 8, monthCount: 12)
    default:
      json = resetHistoryJSON(range: range, startYear: 2026, startMonth: 7, monthCount: 1)
    }

    #expect(try decodeHistory(json).range.rawValue == range)
  }

  @Test
  func decodesNaturalMonthBoundariesAcrossDaylightSavingTime() throws {
    let history = try decodeHistory(resetHistoryJSON(timeZoneIdentifier: "America/New_York"))

    #expect(history.months.first?.from == ISO8601DateFormatter().date(from: "2026-02-01T05:00:00Z"))
    #expect(history.months[1].to == ISO8601DateFormatter().date(from: "2026-04-01T04:00:00Z"))
  }

  @Test(arguments: [
    resetHistoryJSON(range: "24m"),
    resetHistoryJSON().replacingOccurrences(of: "\"range\":\"6m\",\n", with: ""),
  ])
  func rejectsUnknownOrMissingRange(_ json: String) {
    expectDecodingFailure(json)
  }

  @Test(arguments: [
    resetHistoryJSON(range: "3m", startYear: 2026, startMonth: 6, monthCount: 2),
    resetHistoryJSON(range: "6m", startYear: 2026, startMonth: 3, monthCount: 5),
    resetHistoryJSON(range: "12m", startYear: 2025, startMonth: 9, monthCount: 11),
    resetHistoryJSON(range: "all", monthCount: 0),
  ])
  func rejectsInvalidRangeBucketCounts(_ json: String) {
    expectDecodingFailure(json)
  }

  @Test(arguments: [
    resetHistoryJSON().replacingOccurrences(of: "\"2026-03\"", with: "\"2026-02\""),
    resetHistoryJSON().replacingOccurrences(of: "\"2026-04\"", with: "\"2026-05\""),
    resetHistoryJSON().replacingOccurrences(
      of: "\"2026-02\"", with: "\"2026-07\"", options: [], range: nil),
    resetHistoryJSON().replacingOccurrences(of: "\"2026-02\"", with: "\"2026-2\""),
  ])
  func rejectsDuplicateSkippedReversedOrMalformedMonthIdentifiers(_ json: String) {
    expectDecodingFailure(json)
  }

  @Test
  func rejectsBucketOutsideNaturalMonthBoundaries() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: "\"to\":\"2026-04-30T16:00:00Z\"",
      with: "\"to\":\"2026-04-30T15:00:00Z\""
    )

    expectDecodingFailure(json)
  }

  @Test
  func rejectsFinalBucketOutsideGeneratedAtMonth() {
    let json = resetHistoryJSON(startYear: 2026, startMonth: 1, monthCount: 6)

    expectDecodingFailure(json)
  }

  @Test
  func rejectsCurrentMonthThatDiffersFromFinalBucket() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: "\"count\":7}\n      },\n      \"months\"",
      with: "\"count\":8}\n      },\n      \"months\""
    )

    expectDecodingFailure(json)
  }

  @Test
  func rejectsCurrentIntervalsOutsideGeneratedAtNaturalBuckets() {
    let generatedAt = ISO8601DateFormatter().date(from: "2026-07-19T09:00:00Z")!
    let current = resetHistoryCurrentIntervals(
      generatedAt: generatedAt,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    let formatter = ISO8601DateFormatter()
    let shiftedWeekFrom = formatter.string(from: generatedAt.addingTimeInterval(-86_400))
    let shiftedMonthFrom = formatter.string(from: generatedAt.addingTimeInterval(-86_400))

    expectDecodingFailure(
      resetHistoryJSON().replacingOccurrences(of: current.weekFrom, with: shiftedWeekFrom)
    )
    expectDecodingFailure(
      resetHistoryJSON().replacingOccurrences(of: current.monthFrom, with: shiftedMonthFrom)
    )
  }

  @Test(arguments: [
    """
    {"id":"reset-6","reset_at":"2026-07-19T11:21:34Z"},
    {"id":"reset-5","reset_at":"2026-07-19T10:21:34Z"},
    {"id":"reset-4","reset_at":"2026-07-19T09:21:34Z"},
    {"id":"reset-3","reset_at":"2026-07-19T08:21:34Z"},
    {"id":"reset-2","reset_at":"2026-07-19T07:21:34Z"},
    {"id":"reset-1","reset_at":"2026-07-19T06:21:34Z"}
    """,
    """
    {"id":"reset-1","reset_at":"2026-07-19T09:21:34Z"},
    {"id":"reset-1","reset_at":"2026-07-19T08:21:34Z"}
    """,
    """
    {"id":"reset-1","reset_at":"2026-07-19T08:21:34Z"},
    {"id":"reset-2","reset_at":"2026-07-19T09:21:34Z"}
    """,
    """
    {"id":"reset-1","reset_at":"2026-07-19T09:21:34Z"},
    {"id":"reset-2","reset_at":"2026-07-19T09:21:34Z"}
    """,
  ])
  func rejectsInvalidRecentRows(_ recent: String) {
    expectDecodingFailure(resetHistoryJSON(recent: recent))
  }

  @Test(arguments: [
    resetHistoryJSON(timeZoneIdentifier: "Invalid/Zone"),
    resetHistoryJSON().replacingOccurrences(of: "\"count\":2", with: "\"count\":-1"),
    resetHistoryJSON().replacingOccurrences(
      of: "\"from\":\"2026-01-31T16:00:00Z\"",
      with: "\"from\":\"2026-02-01T00:00:00Z\""
    ),
  ])
  func rejectsInvalidValues(_ json: String) {
    expectDecodingFailure(json)
  }
}

private func decodeHistory(_ json: String) throws -> ResetHistory {
  try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}

private func expectDecodingFailure(_ json: String) {
  #expect(throws: DecodingError.self) {
    try decodeHistory(json)
  }
}
