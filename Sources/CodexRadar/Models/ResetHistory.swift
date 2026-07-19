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

    guard TimeZone(identifier: timeZone) != nil else {
      throw invalidValue(
        forKey: .timeZone, in: container, description: "Expected a valid time zone.")
    }
    try validate(interval: current.week, forKey: .current, in: container)
    try validate(interval: current.month, forKey: .current, in: container)
    for month in months {
      try validate(interval: month, forKey: .months, in: container)
    }

    let expectedMonths = (1...12).map { String(format: "%04d-%02d", year, $0) }
    guard months.map(\.month) == expectedMonths else {
      throw invalidValue(
        forKey: .months,
        in: container,
        description: "Expected one ordered summary for each month of the requested year."
      )
    }
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
