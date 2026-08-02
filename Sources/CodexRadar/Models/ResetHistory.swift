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
  let recent: [ResetHistoryEvent]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case timeZone = "time_zone"
    case range
    case current
    case months
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

    guard schemaVersion == "1.1" else {
      throw invalidValue(
        forKey: .schemaVersion,
        in: container,
        description: "Expected reset history schema version 1.1."
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
    try validateRecent(in: container)
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
    guard months.allSatisfy({
      $0.count >= recentCount(from: $0.from, to: $0.to)
    }) else {
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
