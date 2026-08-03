import Foundation

struct ResetCounts: Decodable, Equatable, Sendable {
  let hard: Int
  let banked: Int
  let both: Int

  func validate() throws {
    guard
      hard >= 0,
      banked >= 0,
      both >= 0,
      both <= hard,
      both <= banked
    else {
      throw ResetCountsValidationError.invalidCounts
    }
  }
}

private enum ResetCountsValidationError: Error {
  case invalidCounts
}

struct ResetHistoryInterval: Decodable, Equatable, Sendable {
  let from: Date
  let to: Date
  let count: Int
  let counts: ResetCounts
}

struct ResetMonthSummary: Decodable, Equatable, Identifiable, Sendable {
  let month: String
  let from: Date
  let to: Date
  let count: Int
  let counts: ResetCounts

  var id: String { month }
}

struct ResetHistoryEvent: Decodable, Equatable, Identifiable, Sendable {
  let id: String
  let resetAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case resetAt = "reset_at"
  }
}

struct ResetHistoryDay: Decodable, Equatable, Identifiable, Sendable {
  let day: String
  let from: Date
  let to: Date
  let count: Int
  let counts: ResetCounts

  var id: String { day }
}

struct ResetHistoryCurrent: Decodable, Equatable, Sendable {
  let week: ResetHistoryInterval
  let month: ResetHistoryInterval
}

struct ResetHistory: Decodable, Equatable, Sendable {
  let schemaVersion: String
  let generatedAt: Date
  let timeZone: String
  let range: ResetHistoryRange
  let current: ResetHistoryCurrent
  let months: [ResetMonthSummary]
  let radarDays: [ResetHistoryDay]?
  let recent: [ResetHistoryEvent]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case timeZone = "time_zone"
    case range
    case current
    case months
    case days
    case recent
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    timeZone = try container.decode(String.self, forKey: .timeZone)
    range = try container.decode(ResetHistoryRange.self, forKey: .range)
    current = try container.decode(ResetHistoryCurrent.self, forKey: .current)
    months = try container.decode([ResetMonthSummary].self, forKey: .months)
    recent = try container.decode([ResetHistoryEvent].self, forKey: .recent)

    switch schemaVersion {
    case "1.1":
      guard !container.contains(.days) else {
        throw DecodingError.dataCorruptedError(
          forKey: .days,
          in: container,
          debugDescription: "History schema 1.1 cannot contain reset radar days."
        )
      }
      radarDays = nil
    case "1.2":
      radarDays = try container.decode([ResetHistoryDay].self, forKey: .days)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Expected reset history schema 1.1 or 1.2."
      )
    }
    guard let decodedTimeZone = TimeZone(identifier: timeZone) else {
      throw invalidValue(
        forKey: .timeZone, in: container, description: "Expected a valid time zone.")
    }
    try validate(interval: current.week, forKey: .current, in: container)
    try validate(interval: current.month, forKey: .current, in: container)
    try validateCurrentBoundaries(
      timeZone: decodedTimeZone,
      forKey: .current,
      in: container
    )
    try validateMonths(timeZone: decodedTimeZone, in: container)
    try validateRadarDays(timeZone: decodedTimeZone, in: container)
    try validateRecent(in: container)
  }

  private func validateRadarDays(
    timeZone: TimeZone,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
    guard let radarDays else { return }
    guard radarDays.count == 30 else {
      throw invalidValue(
        forKey: .days,
        in: container,
        description: "Expected exactly 30 reset radar days."
      )
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let expectedLastStart = calendar.startOfDay(for: generatedAt)
    guard
      let expectedFirstStart = calendar.date(
        byAdding: .day,
        value: -(radarDays.count - 1),
        to: expectedLastStart
      ),
      radarDays.first?.from == expectedFirstStart,
      radarDays.last?.from == expectedLastStart
    else {
      throw invalidValue(
        forKey: .days,
        in: container,
        description: "Reset radar days must cover generated_at and the preceding 29 local days."
      )
    }

    var previousEnd: Date?
    for day in radarDays {
      do {
        try day.counts.validate()
      } catch {
        throw invalidValue(
          forKey: .days,
          in: container,
          description: "Reset radar counts must be nonnegative."
        )
      }
      guard
        day.count == day.counts.hard,
        hasValidRadarClassification(day.counts),
        let expectedInterval = naturalDayInterval(
          for: day.day,
          calendar: calendar
        ),
        expectedInterval.start == day.from,
        expectedInterval.end == day.to,
        previousEnd == nil || previousEnd == day.from
      else {
        throw invalidValue(
          forKey: .days,
          in: container,
          description:
            "Reset radar days must be contiguous natural days with one valid classification."
        )
      }
      previousEnd = day.to
    }

    let currentWeekCounts = radarDays.reduce(
      into: (hard: 0, banked: 0, both: 0)
    ) { result, day in
      guard day.from >= current.week.from, day.to <= current.week.to else { return }
      result.hard += day.counts.hard
      result.banked += day.counts.banked
      result.both += day.counts.both
    }
    guard
      currentWeekCounts.hard == current.week.counts.hard,
      currentWeekCounts.banked == current.week.counts.banked,
      currentWeekCounts.both == current.week.counts.both
    else {
      throw invalidValue(
        forKey: .days,
        in: container,
        description: "Reset radar days must match the current week counts."
      )
    }
  }

  private func naturalDayInterval(
    for identifier: String,
    calendar: Calendar
  ) -> DateInterval? {
    guard
      identifier.range(
        of: #"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"#,
        options: .regularExpression
      ) != nil
    else { return nil }
    let parts = identifier.split(separator: "-")
    guard
      parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    let components = DateComponents(
      timeZone: calendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: 0,
      minute: 0,
      second: 0
    )
    guard
      let candidate = calendar.date(from: components),
      let interval = calendar.dateInterval(of: .day, for: candidate)
    else { return nil }
    let resolved = calendar.dateComponents(
      [.year, .month, .day],
      from: interval.start
    )
    guard
      resolved.year == year,
      resolved.month == month,
      resolved.day == day
    else { return nil }
    return interval
  }

  private func hasValidRadarClassification(_ counts: ResetCounts) -> Bool {
    switch (counts.hard, counts.banked, counts.both) {
    case (0, 0, 0): true
    case (let hard, 0, 0) where hard > 0: true
    case (0, let banked, 0) where banked > 0: true
    case (let hard, let banked, let both)
    where hard > 0 && hard == banked && banked == both: true
    default: false
    }
  }

  private func validateMonths(
    timeZone: TimeZone,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
    guard !months.isEmpty else {
      throw invalidValue(
        forKey: .months, in: container, description: "Expected at least one month summary.")
    }
    if let expectedCount = range.fixedMonthCount, months.count != expectedCount {
      throw invalidValue(
        forKey: .months,
        in: container,
        description: "Expected the fixed range to contain its exact number of months."
      )
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var previousStart: Date?

    for month in months {
      try validate(interval: month, forKey: .months, in: container)
      guard let components = monthComponents(from: month.month),
        let expectedFrom = calendar.date(from: components),
        let expectedTo = calendar.date(byAdding: .month, value: 1, to: expectedFrom),
        month.from == expectedFrom,
        month.to == expectedTo
      else {
        throw invalidValue(
          forKey: .months,
          in: container,
          description:
            "Month intervals must match their natural boundaries in the response time zone."
        )
      }
      if let previousStart,
        calendar.date(byAdding: .month, value: 1, to: previousStart) != expectedFrom
      {
        throw invalidValue(
          forKey: .months,
          in: container,
          description: "Month summaries must be contiguous and strictly ascending."
        )
      }
      previousStart = expectedFrom
    }

    guard let expectedCurrentMonth = calendar.dateInterval(of: .month, for: generatedAt),
      let finalMonth = months.last,
      finalMonth.from == expectedCurrentMonth.start,
      finalMonth.to == expectedCurrentMonth.end
    else {
      throw invalidValue(
        forKey: .months,
        in: container,
        description: "The final month summary must contain generated_at."
      )
    }
    guard current.month.from == finalMonth.from,
      current.month.to == finalMonth.to,
      current.month.count == finalMonth.count,
      current.month.counts == finalMonth.counts
    else {
      throw invalidValue(
        forKey: .current,
        in: container,
        description: "Current month must equal the final month summary."
      )
    }
  }

  private func validateRecent(in container: KeyedDecodingContainer<CodingKeys>) throws {
    guard recent.count <= 5 else {
      throw invalidValue(
        forKey: .recent,
        in: container,
        description: "Expected no more than five recent reset events."
      )
    }
    guard Set(recent.map(\.id)).count == recent.count else {
      throw invalidValue(
        forKey: .recent, in: container, description: "Recent reset event IDs must be unique.")
    }
    guard recent.allSatisfy({ $0.resetAt <= generatedAt }) else {
      throw invalidValue(
        forKey: .recent,
        in: container,
        description: "Recent reset events cannot be newer than generated_at."
      )
    }
    let orderedRecent = recent.sorted { lhs, rhs in
      if lhs.resetAt != rhs.resetAt {
        return lhs.resetAt > rhs.resetAt
      }
      return lhs.id > rhs.id
    }
    guard recent == orderedRecent else {
      throw invalidValue(
        forKey: .recent,
        in: container,
        description: "Recent reset events must use stable descending order."
      )
    }
    guard
      current.week.count >= recentCount(from: current.week.from, to: current.week.to),
      current.month.count >= recentCount(from: current.month.from, to: current.month.to)
    else {
      throw invalidValue(
        forKey: .current,
        in: container,
        description: "Current counts cannot be lower than matching recent reset events."
      )
    }
    guard
      months.allSatisfy({
        $0.count >= recentCount(from: $0.from, to: $0.to)
      })
    else {
      throw invalidValue(
        forKey: .months,
        in: container,
        description: "Month counts cannot be lower than matching recent reset events."
      )
    }
  }

  private func recentCount(from: Date, to: Date) -> Int {
    recent.count { event in
      event.resetAt >= from && event.resetAt < to
    }
  }

  private func monthComponents(from identifier: String) -> DateComponents? {
    guard
      identifier.range(
        of: #"^\d{4}-(0[1-9]|1[0-2])$"#,
        options: .regularExpression
      ) != nil
    else { return nil }
    let parts = identifier.split(separator: "-")
    guard
      parts.count == 2,
      let year = Int(parts[0]),
      let month = Int(parts[1])
    else { return nil }
    return DateComponents(year: year, month: month, day: 1)
  }

  private func validateCurrentBoundaries(
    timeZone: TimeZone,
    forKey key: CodingKeys,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
    var weekCalendar = Calendar(identifier: .iso8601)
    weekCalendar.timeZone = timeZone
    var monthCalendar = Calendar(identifier: .gregorian)
    monthCalendar.timeZone = timeZone

    guard
      let expectedWeek = weekCalendar.dateInterval(of: .weekOfYear, for: generatedAt),
      let expectedMonth = monthCalendar.dateInterval(of: .month, for: generatedAt),
      current.week.from == expectedWeek.start,
      current.week.to == expectedWeek.end,
      current.month.from == expectedMonth.start,
      current.month.to == expectedMonth.end
    else {
      throw invalidValue(
        forKey: key,
        in: container,
        description: "Current intervals must match generated_at in the response time zone."
      )
    }
  }

  private func validate(
    interval: ResetHistoryInterval,
    forKey key: CodingKeys,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
    do {
      try interval.counts.validate()
    } catch {
      throw invalidValue(
        forKey: key,
        in: container,
        description: "Reset counts must be nonnegative and both cannot exceed hard or banked."
      )
    }
    guard interval.count == interval.counts.hard else {
      throw invalidValue(
        forKey: key,
        in: container,
        description: "Legacy count must equal the hard reset count."
      )
    }
    guard interval.count >= 0 else {
      throw invalidValue(
        forKey: key, in: container, description: "Interval counts cannot be negative.")
    }
    guard interval.from < interval.to else {
      throw invalidValue(
        forKey: key, in: container, description: "Interval start must precede its end.")
    }
  }

  private func validate(
    interval: ResetMonthSummary,
    forKey key: CodingKeys,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
    try validate(
      interval: ResetHistoryInterval(
        from: interval.from,
        to: interval.to,
        count: interval.count,
        counts: interval.counts
      ),
      forKey: key,
      in: container
    )
  }

  private func invalidValue(
    forKey key: CodingKeys,
    in container: KeyedDecodingContainer<CodingKeys>,
    description: String
  ) -> DecodingError {
    DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: description)
  }
}
