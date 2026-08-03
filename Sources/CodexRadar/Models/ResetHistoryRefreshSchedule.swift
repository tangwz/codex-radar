import Foundation

enum ResetHistoryRefreshSchedule {
  static func nextBoundary(
    after generatedAt: Date,
    timeZone: TimeZone
  ) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.dateInterval(of: .day, for: generatedAt)?.end.addingTimeInterval(1)
  }
}
