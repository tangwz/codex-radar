import Foundation

enum ResetHistoryRefreshSchedule {
  static func nextBoundary(
    after generatedAt: Date,
    timeZone: TimeZone
  ) -> Date? {
    var weekCalendar = Calendar(identifier: .iso8601)
    weekCalendar.timeZone = timeZone
    var monthCalendar = Calendar(identifier: .gregorian)
    monthCalendar.timeZone = timeZone

    guard
      let week = weekCalendar.dateInterval(of: .weekOfYear, for: generatedAt),
      let month = monthCalendar.dateInterval(of: .month, for: generatedAt)
    else {
      return nil
    }
    return min(week.end, month.end).addingTimeInterval(1)
  }
}
