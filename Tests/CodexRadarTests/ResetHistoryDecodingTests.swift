import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryDecodingTests {
  @Test
  func decodesV11WithoutRadarCapability() throws {
    let history = try decodeHistory(resetHistoryJSON())

    #expect(history.radarDays == nil)
  }

  @Test
  func decodesV12WithThirtyValidatedRadarDays() throws {
    let days = resetHistoryDayJSONs(
      activeKinds: [0: .hard(2), 1: .banked(1), 2: .hardAndBanked(1)]
    )
    let history = try decodeHistory(resetHistoryV12JSON(days: days))

    #expect(history.schemaVersion == "1.2")
    #expect(history.radarDays?.count == 30)
    #expect(history.radarDays?[0].counts == ResetCounts(hard: 2, banked: 0, both: 0))
    #expect(history.radarDays?[1].counts == ResetCounts(hard: 0, banked: 1, both: 0))
    #expect(history.radarDays?[2].counts == ResetCounts(hard: 1, banked: 1, both: 1))
  }

  @Test
  func rejectsMissingOrIncorrectRadarDayCountForV12() {
    expectDecodingFailure(resetHistoryJSON(schemaVersion: "1.2"))
    expectDecodingFailure(
      resetHistoryV12JSON(days: resetHistoryDayJSONs(dayCount: 29)))
    expectDecodingFailure(
      resetHistoryV12JSON(days: resetHistoryDayJSONs(dayCount: 31)))
  }

  @Test
  func rejectsDuplicateDescendingAndNoncontiguousRadarDays() {
    let valid = resetHistoryDayJSONs()
    var duplicate = valid
    duplicate[1] = duplicate[0]
    expectDecodingFailure(resetHistoryV12JSON(days: duplicate))
    expectDecodingFailure(resetHistoryV12JSON(days: Array(valid.reversed())))

    var skipped = resetHistoryDayJSONs(dayCount: 31)
    skipped.remove(at: 1)
    expectDecodingFailure(resetHistoryV12JSON(days: skipped))
  }

  @Test
  func validatesNaturalRadarDayBoundariesAcrossDaylightSavingTime() throws {
    let generatedAt = "2026-03-09T12:00:00Z"
    let timeZone = "America/New_York"
    let days = resetHistoryDayJSONs(
      generatedAt: generatedAt,
      timeZoneIdentifier: timeZone
    )
    let history = try decodeHistory(
      resetHistoryV12JSON(
        generatedAt: generatedAt,
        timeZoneIdentifier: timeZone,
        days: days
      ))
    let transition = try #require(history.radarDays?.first { $0.day == "2026-03-08" })
    #expect(transition.to.timeIntervalSince(transition.from) == 23 * 60 * 60)

    let malformed = days.map { day in
      day.contains("\"day\":\"2026-03-08\"")
        ? day.replacingOccurrences(
          of: "\"from\":\"2026-03-08T05:00:00Z\"",
          with: "\"from\":\"2026-03-08T06:00:00Z\"")
        : day
    }
    expectDecodingFailure(
      resetHistoryV12JSON(
        generatedAt: generatedAt,
        timeZoneIdentifier: timeZone,
        days: malformed
      ))
  }

  @Test
  func validatesNaturalRadarDayWhenLocalMidnightIsSkipped() throws {
    let generatedAt = "2018-11-10T12:00:00Z"
    let timeZone = "America/Sao_Paulo"
    let days = resetHistoryDayJSONs(
      generatedAt: generatedAt,
      timeZoneIdentifier: timeZone
    )

    let history = try decodeHistory(
      resetHistoryV12JSON(
        generatedAt: generatedAt,
        timeZoneIdentifier: timeZone,
        days: days
      )
    )
    let skippedMidnight = try #require(
      history.radarDays?.first { $0.day == "2018-11-04" }
    )

    #expect(
      skippedMidnight.from
        == ISO8601DateFormatter().date(from: "2018-11-04T03:00:00Z")
    )
    #expect(
      skippedMidnight.to
        == ISO8601DateFormatter().date(from: "2018-11-05T02:00:00Z")
    )
    #expect(skippedMidnight.to.timeIntervalSince(skippedMidnight.from) == 23 * 60 * 60)
  }

  @Test
  func rejectsRadarWindowThatDoesNotEndOnGeneratedAtLocalDay() {
    expectDecodingFailure(
      resetHistoryJSON(
        schemaVersion: "1.2",
        generatedAt: "2026-07-20T09:00:00Z",
        days: resetHistoryDayJSONs().joined(separator: ",")
      ))
  }

  @Test
  func rejectsInvalidRadarCountsAndMixedClassification() {
    let baseDate = ISO8601DateFormatter().date(from: "2026-06-20T00:00:00Z")!
    let invalidRows = [
      resetHistoryDayJSON(
        date: baseDate,
        timeZoneIdentifier: "Asia/Shanghai",
        kind: .hard(-1)
      ),
      resetHistoryDayJSON(
        date: baseDate,
        timeZoneIdentifier: "Asia/Shanghai",
        kind: .hard(1),
        count: 0
      ),
      resetHistoryDayJSON(
        date: baseDate,
        timeZoneIdentifier: "Asia/Shanghai",
        kind: .inactive
      ).replacingOccurrences(
        of: "\"count\":0,\"counts\":{\"hard\":0,\"banked\":0,\"both\":0}",
        with: "\"count\":2,\"counts\":{\"hard\":2,\"banked\":1,\"both\":0}"
      ),
    ]

    for invalidRow in invalidRows {
      var days = resetHistoryDayJSONs()
      days[0] = invalidRow
      expectDecodingFailure(resetHistoryV12JSON(days: days))
    }
  }

  @Test
  func rejectsRadarDaysThatDisagreeWithCurrentWeekCounts() {
    expectDataCorruptedFailure(
      resetHistoryV12JSON(
        currentWeekCounts: ResetHistoryCountsFixture(hard: 1, banked: 0, both: 0)
      ),
      forKey: "days"
    )
  }

  @Test
  func rejectsOverflowingRadarWeekTotals() {
    let days = resetHistoryDayJSONs(
      activeKinds: [
        23: .hard(Int.max),
        24: .hard(Int.max),
      ]
    )

    expectDataCorruptedFailure(
      resetHistoryV12JSON(days: days),
      forKey: "days"
    )
  }

  @Test
  func rejectsRadarMonthSubtotalAboveMonthSummary() {
    let days = resetHistoryDayJSONs(activeKinds: [15: .hard(8)])

    expectDataCorruptedFailure(
      resetHistoryV12JSON(
        days: days,
        currentMonthCounts: ResetHistoryCountsFixture(hard: 7, banked: 0, both: 0)
      ),
      forKey: "days"
    )
  }

  @Test
  func rejectsRadarMonthSubtotalThatDoesNotMatchFullyCoveredElapsedMonth() {
    let days = resetHistoryDayJSONs(activeKinds: [15: .hard(2)])

    expectDataCorruptedFailure(
      resetHistoryV12JSON(
        days: days,
        currentMonthCounts: ResetHistoryCountsFixture(hard: 7, banked: 0, both: 0)
      ),
      forKey: "days"
    )
  }

  @Test
  func rejectsV11ResponseContainingRadarDays() {
    expectDecodingFailure(
      resetHistoryJSON(
        days: resetHistoryDayJSONs().joined(separator: ",")
      ))
  }

  @Test
  func decodesSixMonthRangeEndingInGeneratedAtMonth() throws {
    let history = try decodeHistory(resetHistoryJSON())

    #expect(history.schemaVersion == "1.1")
    #expect(history.range == .sixMonths)
    #expect(
      history.months.map(\.month) == [
        "2026-02", "2026-03", "2026-04",
        "2026-05", "2026-06", "2026-07",
      ])
    #expect(history.current.month.count == history.months.last?.count)
    #expect(history.current.week.counts == ResetCounts(hard: 2, banked: 3, both: 2))
    #expect(history.current.month.counts == ResetCounts(hard: 7, banked: 3, both: 2))
    #expect(history.months.first?.counts == ResetCounts(hard: 2, banked: 3, both: 2))
  }

  @Test
  func rejectsMissingCounts() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: ",\"counts\":{\"hard\":2,\"banked\":3,\"both\":2}",
      with: ""
    )

    expectDecodingFailure(json)
  }

  @Test(arguments: ["hard", "banked", "both"])
  func rejectsNegativeResetCounts(_ field: String) {
    let validValue = field == "banked" ? 3 : 2
    let json = resetHistoryJSON().replacingOccurrences(
      of: "\"\(field)\":\(validValue)",
      with: "\"\(field)\":-1"
    )

    expectDecodingFailure(json)
  }

  @Test
  func rejectsLegacyCountDifferentFromHardCount() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: "\"hard\":2",
      with: "\"hard\":3"
    )

    expectDecodingFailure(json)
  }

  @Test
  func rejectsBothCountGreaterThanHardCount() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: "\"hard\":2,\"banked\":3,\"both\":2",
      with: "\"hard\":2,\"banked\":3,\"both\":3"
    )

    expectDecodingFailure(json)
  }

  @Test
  func rejectsBothCountGreaterThanBankedCount() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: "\"hard\":2,\"banked\":3,\"both\":2",
      with: "\"hard\":2,\"banked\":1,\"both\":2"
    )

    expectDecodingFailure(json)
  }

  @Test
  func rejectsUnsupportedSchemaVersion() {
    expectDecodingFailure(resetHistoryJSON(schemaVersion: "1.0"))
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
    expectDecodingFailure(resetHistoryJSON(currentMonthCount: 8))
  }

  @Test
  func rejectsCurrentMonthWithDifferentBankedCountFromFinalBucket() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: currentMonthJSON(banked: 3, both: 2),
      with: currentMonthJSON(banked: 4, both: 2)
    )

    expectDataCorruptedFailure(json, forKey: "current")
  }

  @Test
  func rejectsCurrentMonthWithDifferentBothCountFromFinalBucket() {
    let json = resetHistoryJSON().replacingOccurrences(
      of: currentMonthJSON(banked: 3, both: 2),
      with: currentMonthJSON(banked: 3, both: 1)
    )

    expectDataCorruptedFailure(json, forKey: "current")
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

  @Test
  func rejectsRecentEventAfterGeneratedAt() {
    expectDecodingFailure(
      resetHistoryJSON(
        recent: """
          {"id":"reset-future","reset_at":"2026-07-19T09:00:01Z"}
          """
      )
    )
  }

  @Test
  func rejectsCurrentAggregatesBelowMatchingRecentCount() {
    let generatedAt = ISO8601DateFormatter().date(from: "2026-07-19T09:00:00Z")!
    let current = resetHistoryCurrentIntervals(
      generatedAt: generatedAt,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    let week = resetHistoryJSON().replacingOccurrences(
      of:
        "\"week\":{\"from\":\"\(current.weekFrom)\",\"to\":\"\(current.weekTo)\",\"count\":2,\"counts\":{\"hard\":2,\"banked\":3,\"both\":2}}",
      with:
        "\"week\":{\"from\":\"\(current.weekFrom)\",\"to\":\"\(current.weekTo)\",\"count\":1,\"counts\":{\"hard\":1,\"banked\":3,\"both\":1}}"
    )
    let currentMonthSummary = resetHistoryMonthSummaryJSON(
      year: 2026,
      month: 7,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    let insufficientMonthSummary = resetHistoryMonthSummaryJSON(
      year: 2026,
      month: 7,
      timeZoneIdentifier: "Asia/Shanghai",
      count: 1
    )
    let month = resetHistoryJSON(currentMonthCount: 1).replacingOccurrences(
      of: currentMonthSummary,
      with: insufficientMonthSummary
    )

    expectDecodingFailure(week)
    expectDecodingFailure(month)
  }

  @Test
  func rejectsMonthSummaryBelowMatchingRecentCount() {
    let recent = """
      {"id":"reset-2","reset_at":"2026-02-10T08:00:00Z"},
      {"id":"reset-1","reset_at":"2026-02-09T08:00:00Z"}
      """
    let february = resetHistoryMonthSummaryJSON(
      year: 2026,
      month: 2,
      timeZoneIdentifier: "Asia/Shanghai"
    )
    let insufficientFebruary = resetHistoryMonthSummaryJSON(
      year: 2026,
      month: 2,
      timeZoneIdentifier: "Asia/Shanghai",
      count: 1
    )
    let json = resetHistoryJSON(recent: recent).replacingOccurrences(
      of: february,
      with: insufficientFebruary
    )

    expectDecodingFailure(json)
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

private func currentMonthJSON(banked: Int, both: Int) -> String {
  let generatedAt = ISO8601DateFormatter().date(from: "2026-07-19T09:00:00Z")!
  let current = resetHistoryCurrentIntervals(
    generatedAt: generatedAt,
    timeZoneIdentifier: "Asia/Shanghai"
  )
  return """
    "month":{"from":"\(current.monthFrom)","to":"\(current.monthTo)","count":7,"counts":{"hard":7,"banked":\(banked),"both":\(both)}}
    """
}

private func expectDataCorruptedFailure(_ json: String, forKey key: String) {
  do {
    _ = try decodeHistory(json)
    Issue.record("Expected decoding to fail.")
  } catch let DecodingError.dataCorrupted(context) {
    #expect(context.codingPath.last?.stringValue == key)
  } catch {
    Issue.record("Expected a data-corrupted decoding error, got \(error).")
  }
}

private func expectDecodingFailure(_ json: String) {
  #expect(throws: DecodingError.self) {
    try decodeHistory(json)
  }
}
