import Foundation

extension ResetHistory {
  /// Construct the app's read model from a complete public announcement list.
  /// Legacy wire decoders remain only for old fixtures; no backend is queried.
  init(
    codexResets records: [CodexResetsRecord],
    now: Date,
    timeZone: TimeZone,
    range: ResetHistoryRange
  ) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    guard let month = calendar.dateInterval(of: .month, for: now),
      let week = calendar.dateInterval(of: .weekOfYear, for: now)
    else { throw CodexResetsError.invalidResponse }
    let ordered = records.filter { $0.announced_at <= now }.sorted {
      $0.announced_at == $1.announced_at ? $0.id > $1.id : $0.announced_at > $1.announced_at
    }
    func counts(in interval: DateInterval) -> ResetCounts {
      let subset = ordered.filter { $0.announced_at >= interval.start && $0.announced_at < interval.end }
      return ResetCounts(
        hard: subset.count { $0.reset_type == .regular },
        banked: subset.count { $0.reset_type == .banked },
        both: 0 // Public records do not have the old combined-event classification.
      )
    }
    func interval(_ value: DateInterval) -> ResetHistoryInterval {
      let c = counts(in: value)
      return ResetHistoryInterval(from: value.start, to: value.end, count: c.hard + c.banked, counts: c)
    }
    func identifier(_ value: Date, includeDay: Bool) -> String {
      let c = calendar.dateComponents([.year, .month, .day], from: value)
      return includeDay
        ? String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        : String(format: "%04d-%02d", c.year!, c.month!)
    }
    let firstMonth: Date
    if let count = range.fixedMonthCount {
      guard let start = calendar.date(byAdding: .month, value: 1 - count, to: month.start) else {
        throw CodexResetsError.invalidResponse
      }
      firstMonth = start
    } else {
      firstMonth = calendar.dateInterval(of: .month, for: ordered.last?.announced_at ?? now)?.start ?? month.start
    }
    var monthly: [ResetMonthSummary] = []
    var cursor = firstMonth
    while cursor <= month.start {
      guard monthly.count < 1200,
        let value = calendar.dateInterval(of: .month, for: cursor), value.end > cursor
      else { throw CodexResetsError.invalidResponse }
      let c = counts(in: value)
      monthly.append(ResetMonthSummary(
        month: identifier(cursor, includeDay: false), from: value.start, to: value.end,
        count: c.hard + c.banked, counts: c
      ))
      cursor = value.end
    }
    var days: [ResetHistoryDay] = []
    for offset in (-29)...0 {
      guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
        let value = calendar.dateInterval(of: .day, for: date)
      else { throw CodexResetsError.invalidResponse }
      let c = counts(in: value)
      days.append(ResetHistoryDay(
        day: identifier(value.start, includeDay: true), from: value.start, to: value.end,
        count: c.hard + c.banked, counts: c
      ))
    }
    schemaVersion = CodexResetsAPI.schema
    generatedAt = now // Time of LOCAL aggregation, not the upstream collector's health.
    self.timeZone = timeZone.identifier
    self.range = range
    current = ResetHistoryCurrent(week: interval(week), month: interval(month))
    months = monthly
    radarDays = days
    recent = ordered.prefix(5).map { ResetHistoryEvent(id: $0.id, resetAt: $0.announced_at) }
  }

  var usesPublicAnnouncements: Bool { schemaVersion == CodexResetsAPI.schema }
}
