import Foundation

struct TokenUsageEvent: Codable, Equatable, Sendable {
  let timestamp: Date
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let turnID: String?
  let model: String?
  let eventIndex: Int?

  init(
    timestamp: Date,
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    turnID: String? = nil,
    model: String? = nil,
    eventIndex: Int? = nil
  ) {
    self.timestamp = timestamp
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.turnID = turnID
    self.model = model
    self.eventIndex = eventIndex
  }

  var totalTokens: Int {
    inputTokens + outputTokens
  }
}

enum TokenUsagePeriod: String, CaseIterable, Identifiable, Sendable {
  case day = "Day"
  case month = "Month"
  case year = "Year"

  var id: Self { self }

  var calendarComponent: Calendar.Component {
    switch self {
    case .day: .day
    case .month: .month
    case .year: .year
    }
  }
}

struct TokenUsageBucket: Identifiable, Equatable, Sendable {
  let startDate: Date
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int

  var id: Date { startDate }
  var totalTokens: Int { inputTokens + outputTokens }
}

enum TokenUsageAggregator {
  static func total(
    _ events: [TokenUsageEvent],
    in period: TokenUsagePeriod,
    at date: Date = .now,
    calendar: Calendar = .current
  ) -> Int {
    guard
      let currentStart = calendar.dateInterval(of: period.calendarComponent, for: date)?.start
    else {
      return 0
    }
    return aggregate(events, by: period, calendar: calendar)
      .first { $0.startDate == currentStart }?.totalTokens ?? 0
  }

  static func aggregate(
    _ events: [TokenUsageEvent],
    by period: TokenUsagePeriod,
    calendar: Calendar = .current
  ) -> [TokenUsageBucket] {
    struct Totals {
      var input = 0
      var cached = 0
      var output = 0
    }

    let grouped = events.reduce(into: [Date: Totals]()) { result, event in
      guard
        let startDate = calendar.dateInterval(
          of: period.calendarComponent,
          for: event.timestamp
        )?.start
      else {
        return
      }

      result[startDate, default: Totals()].input += event.inputTokens
      result[startDate, default: Totals()].cached += event.cachedInputTokens
      result[startDate, default: Totals()].output += event.outputTokens
    }

    return grouped.map { startDate, totals in
      TokenUsageBucket(
        startDate: startDate,
        inputTokens: totals.input,
        cachedInputTokens: totals.cached,
        outputTokens: totals.output
      )
    }
    .sorted { $0.startDate < $1.startDate }
  }
}
