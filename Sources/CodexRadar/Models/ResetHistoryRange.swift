import Foundation

enum ResetHistoryRange: String, CaseIterable, Decodable, Equatable, Identifiable, Sendable {
  case threeMonths = "3m"
  case sixMonths = "6m"
  case twelveMonths = "12m"
  case all

  var id: String { rawValue }

  var fixedMonthCount: Int? {
    switch self {
    case .threeMonths: 3
    case .sixMonths: 6
    case .twelveMonths: 12
    case .all: nil
    }
  }

  var requestedRange: ResetHistoryRange {
    self == .threeMonths ? .sixMonths : self
  }

  var queryValue: String? {
    self == .sixMonths ? nil : rawValue
  }

  func covers(_ range: ResetHistoryRange) -> Bool {
    if self == .all { return true }
    guard let available = fixedMonthCount, let required = range.fixedMonthCount else {
      return self == range
    }
    return available >= required
  }
}
