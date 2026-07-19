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
  count: Int? = nil
) -> String {
  let interval = resetHistoryMonthInterval(
    year: year,
    month: month,
    timeZoneIdentifier: timeZoneIdentifier
  )
  return """
    {"month":"\(identifier ?? String(format: "%04d-%02d", year, month))","from":"\(from ?? interval.from)","to":"\(to ?? interval.to)","count":\(count ?? month)}
    """
}

func resetHistoryMonthSummariesJSON(
  year: Int,
  timeZoneIdentifier: String,
  monthCount: Int = 12
) -> String {
  (1...monthCount).map { month in
    resetHistoryMonthSummaryJSON(
      year: year,
      month: month,
      timeZoneIdentifier: timeZoneIdentifier
    )
  }.joined(separator: ",")
}
