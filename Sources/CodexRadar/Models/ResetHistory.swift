import Foundation

struct ResetHistoryInterval: Decodable, Equatable, Sendable {
  let from: Date
  let to: Date
  let count: Int
}

struct ResetMonthSummary: Decodable, Equatable, Identifiable, Sendable {
  let month: String
  let from: Date
  let to: Date
  let count: Int

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
  let year: Int
  let availableYears: [Int]
  let current: ResetHistoryCurrent
  let months: [ResetMonthSummary]
  let recent: [ResetHistoryEvent]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case timeZone = "time_zone"
    case year
    case availableYears = "available_years"
    case current
    case months
    case recent
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    timeZone = try container.decode(String.self, forKey: .timeZone)
    year = try container.decode(Int.self, forKey: .year)
    availableYears = try container.decode([Int].self, forKey: .availableYears)
    current = try container.decode(ResetHistoryCurrent.self, forKey: .current)
    months = try container.decode([ResetMonthSummary].self, forKey: .months)
    recent = try container.decode([ResetHistoryEvent].self, forKey: .recent)

    guard let decodedTimeZone = TimeZone(identifier: timeZone) else {
      throw invalidValue(
        forKey: .timeZone, in: container, description: "Expected a valid time zone.")
    }
    let (followingYear, yearOverflow) = year.addingReportingOverflow(1)
    guard !yearOverflow else {
      throw invalidValue(
        forKey: .year,
        in: container,
        description: "Expected a year with a representable following year."
      )
    }
    try validate(interval: current.week, forKey: .current, in: container)
    try validate(interval: current.month, forKey: .current, in: container)
    for month in months {
      try validate(interval: month, forKey: .months, in: container)
    }

    let expectedYearIdentifier = yearIdentifier(for: year)
    let expectedMonths = (1...12).map { month in
      let monthIdentifier = month < 10 ? "0\(month)" : String(month)
      return "\(expectedYearIdentifier)-\(monthIdentifier)"
    }
    guard months.map(\.month) == expectedMonths else {
      throw invalidValue(
        forKey: .months,
        in: container,
        description: "Expected one ordered summary for each month of the requested year."
      )
    }
    try validateMonthBoundaries(
      timeZone: decodedTimeZone,
      followingYear: followingYear,
      forKey: .months,
      in: container
    )
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
  }

  private func yearIdentifier(for year: Int) -> String {
    let value = String(year)
    guard value.count < 4 else { return value }

    let padding = String(repeating: "0", count: 4 - value.count)
    if value.first == "-" {
      return "-\(padding)\(value.dropFirst())"
    }
    return "\(padding)\(value)"
  }

  private func validateMonthBoundaries(
    timeZone: TimeZone,
    followingYear: Int,
    forKey key: CodingKeys,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    for (index, month) in months.enumerated() {
      let monthNumber = index + 1
      let nextYear = monthNumber == 12 ? followingYear : year
      let nextMonth = monthNumber == 12 ? 1 : monthNumber + 1
      guard
        let expectedFrom = naturalMonthBoundary(
          year: year,
          month: monthNumber,
          timeZone: timeZone,
          calendar: calendar
        ),
        let expectedTo = naturalMonthBoundary(
          year: nextYear,
          month: nextMonth,
          timeZone: timeZone,
          calendar: calendar
        ),
        month.from == expectedFrom,
        month.to == expectedTo
      else {
        throw invalidValue(
          forKey: key,
          in: container,
          description:
            "Month intervals must match their natural boundaries in the response time zone."
        )
      }
    }
  }

  private func naturalMonthBoundary(
    year: Int,
    month: Int,
    timeZone: TimeZone,
    calendar: Calendar
  ) -> Date? {
    var components = DateComponents()
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = 1
    components.hour = 0
    components.minute = 0
    components.second = 0
    return calendar.date(from: components)
  }

  private func validate(
    interval: ResetHistoryInterval,
    forKey key: CodingKeys,
    in container: KeyedDecodingContainer<CodingKeys>
  ) throws {
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
      interval: ResetHistoryInterval(from: interval.from, to: interval.to, count: interval.count),
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
