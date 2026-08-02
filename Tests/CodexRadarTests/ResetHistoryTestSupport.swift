import Foundation

struct ResetHistoryCurrentIntervals {
  let weekFrom: String
  let weekTo: String
  let monthFrom: String
  let monthTo: String
}

func resetHistoryCurrentIntervals(
  generatedAt: Date,
  timeZoneIdentifier: String
) -> ResetHistoryCurrentIntervals {
  let timeZone = TimeZone(identifier: timeZoneIdentifier)!
  var weekCalendar = Calendar(identifier: .iso8601)
  weekCalendar.timeZone = timeZone
  var monthCalendar = Calendar(identifier: .gregorian)
  monthCalendar.timeZone = timeZone
  let week = weekCalendar.dateInterval(of: .weekOfYear, for: generatedAt)!
  let month = monthCalendar.dateInterval(of: .month, for: generatedAt)!
  let formatter = ISO8601DateFormatter()
  return ResetHistoryCurrentIntervals(
    weekFrom: formatter.string(from: week.start),
    weekTo: formatter.string(from: week.end),
    monthFrom: formatter.string(from: month.start),
    monthTo: formatter.string(from: month.end)
  )
}

func resetHistoryMonthInterval(
  year: Int,
  month: Int,
  timeZoneIdentifier: String
) -> (from: String, to: String) {
  let timeZone = TimeZone(identifier: timeZoneIdentifier)!
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  let from = calendar.date(
    from: DateComponents(year: year, month: month, day: 1, hour: 0, minute: 0, second: 0)
  )!
  let nextYear = month == 12 ? year + 1 : year
  let nextMonth = month == 12 ? 1 : month + 1
  let to = calendar.date(
    from: DateComponents(
      year: nextYear,
      month: nextMonth,
      day: 1,
      hour: 0,
      minute: 0,
      second: 0
    )
  )!
  let formatter = ISO8601DateFormatter()
  return (formatter.string(from: from), formatter.string(from: to))
}

func resetHistoryMonthSummaryJSON(
  year: Int,
  month: Int,
  timeZoneIdentifier: String,
  identifier: String? = nil,
  from: String? = nil,
  to: String? = nil,
  count: Int? = nil,
  bankedCount: Int = 3,
  bothCount: Int? = nil
) -> String {
  let interval = resetHistoryMonthInterval(
    year: year,
    month: month,
    timeZoneIdentifier: timeZoneIdentifier
  )
  let hardCount = count ?? month
  let resolvedBothCount = bothCount ?? min(2, hardCount, bankedCount)
  return """
    {"month":"\(identifier ?? String(format: "%04d-%02d", year, month))","from":"\(from ?? interval.from)","to":"\(to ?? interval.to)","count":\(hardCount),"counts":{"hard":\(hardCount),"banked":\(bankedCount),"both":\(resolvedBothCount)}}
    """
}

func resetHistoryMonthSummariesJSON(
  startYear: Int,
  startMonth: Int,
  count: Int,
  timeZoneIdentifier: String
) -> String {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
  let start = calendar.date(
    from: DateComponents(year: startYear, month: startMonth, day: 1)
  )!

  return (0..<count).map { offset in
    let date = calendar.date(byAdding: .month, value: offset, to: start)!
    return resetHistoryMonthSummaryJSON(
      year: calendar.component(.year, from: date),
      month: calendar.component(.month, from: date),
      timeZoneIdentifier: timeZoneIdentifier
    )
  }.joined(separator: ",")
}

func resetHistoryJSON(
  schemaVersion: String = "1.1",
  range: String = "6m",
  startYear: Int = 2026,
  startMonth: Int = 2,
  monthCount: Int = 6,
  timeZoneIdentifier: String = "Asia/Shanghai",
  generatedAt: String = "2026-07-19T09:00:00Z",
  currentMonthCount: Int? = nil,
  recent: String = ""
) -> String {
  let boundaryTimeZone =
    TimeZone(identifier: timeZoneIdentifier) == nil ? "UTC" : timeZoneIdentifier
  let generatedAtDate = ISO8601DateFormatter().date(from: generatedAt)!
  let current = resetHistoryCurrentIntervals(
    generatedAt: generatedAtDate,
    timeZoneIdentifier: boundaryTimeZone
  )
  let months = resetHistoryMonthSummariesJSON(
    startYear: startYear,
    startMonth: startMonth,
    count: monthCount,
    timeZoneIdentifier: boundaryTimeZone
  )
  let derivedCurrentMonthCount: Int
  if monthCount > 0 {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: boundaryTimeZone)!
    let start = calendar.date(
      from: DateComponents(year: startYear, month: startMonth, day: 1)
    )!
    let finalMonth = calendar.date(byAdding: .month, value: monthCount - 1, to: start)!
    derivedCurrentMonthCount = calendar.component(.month, from: finalMonth)
  } else {
    derivedCurrentMonthCount = 0
  }
  let resolvedCurrentMonthCount = currentMonthCount ?? derivedCurrentMonthCount
  let formatter = ISO8601DateFormatter()
  let resolvedRecent =
    recent.isEmpty
    ? """
    {"id":"reset-2","reset_at":"\(formatter.string(from: generatedAtDate.addingTimeInterval(-3_600)))"},
    {"id":"reset-1","reset_at":"\(formatter.string(from: generatedAtDate.addingTimeInterval(-7_200)))"}
    """
    : recent

  return """
    {
      "schema_version":"\(schemaVersion)",
      "generated_at":"\(generatedAt)",
      "time_zone":"\(timeZoneIdentifier)",
      "range":"\(range)",
      "current":{
        "week":{"from":"\(current.weekFrom)","to":"\(current.weekTo)","count":2,"counts":{"hard":2,"banked":3,"both":2}},
        "month":{"from":"\(current.monthFrom)","to":"\(current.monthTo)","count":\(resolvedCurrentMonthCount),"counts":{"hard":\(resolvedCurrentMonthCount),"banked":3,"both":\(min(2, resolvedCurrentMonthCount))}}
      },
      "months":[\(months)],
      "recent":[\(resolvedRecent)]
    }
    """
}
