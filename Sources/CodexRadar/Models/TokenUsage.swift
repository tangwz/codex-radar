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
