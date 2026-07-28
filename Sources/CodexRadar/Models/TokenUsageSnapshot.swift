import Foundation

enum TokenUsageCacheVersion {
  static let schema = 1
  static let parser = 1
}

struct TokenUsageMetrics: Codable, Equatable, Sendable {
  let inputTokens: Int
  let outputTokens: Int

  static let zero = TokenUsageMetrics(inputTokens: 0, outputTokens: 0)

  var totalTokens: Int {
    inputTokens + outputTokens
  }
}

struct TokenUsageChartBucket: Codable, Equatable, Identifiable, Sendable {
  let startDate: Date
  let inputTokens: Int
  let outputTokens: Int

  var id: Date { startDate }
  var totalTokens: Int { inputTokens + outputTokens }
  var metrics: TokenUsageMetrics {
    TokenUsageMetrics(inputTokens: inputTokens, outputTokens: outputTokens)
  }
}

struct TokenUsageSnapshot: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let parserVersion: Int
  let generatedAt: Date
  let timeZoneIdentifier: String
  let hasUsageData: Bool
  let dailyBuckets: [TokenUsageChartBucket]
  let monthlyBuckets: [TokenUsageChartBucket]
  let yearlyBuckets: [TokenUsageChartBucket]

  var isCompatible: Bool {
    schemaVersion == TokenUsageCacheVersion.schema
      && parserVersion == TokenUsageCacheVersion.parser
  }

  func buckets(for period: TokenUsagePeriod) -> [TokenUsageChartBucket] {
    switch period {
    case .day: dailyBuckets
    case .month: monthlyBuckets
    case .year: yearlyBuckets
    }
  }

  func metrics(for period: TokenUsagePeriod) -> TokenUsageMetrics {
    buckets(for: period).last?.metrics ?? .zero
  }
}

enum TokenUsageSnapshotBuilder {
  static func make(
    events: [TokenUsageEvent],
    at date: Date,
    timeZone: TimeZone
  ) -> TokenUsageSnapshot {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    return TokenUsageSnapshot(
      schemaVersion: TokenUsageCacheVersion.schema,
      parserVersion: TokenUsageCacheVersion.parser,
      generatedAt: date,
      timeZoneIdentifier: timeZone.identifier,
      hasUsageData: !events.isEmpty,
      dailyBuckets: makeBuckets(
        events: events,
        period: .day,
        count: 14,
        at: date,
        calendar: calendar
      ),
      monthlyBuckets: makeBuckets(
        events: events,
        period: .month,
        count: 12,
        at: date,
        calendar: calendar
      ),
      yearlyBuckets: makeBuckets(
        events: events,
        period: .year,
        count: 6,
        at: date,
        calendar: calendar
      )
    )
  }

  private static func makeBuckets(
    events: [TokenUsageEvent],
    period: TokenUsagePeriod,
    count: Int,
    at date: Date,
    calendar: Calendar
  ) -> [TokenUsageChartBucket] {
    guard
      let currentStart = calendar.dateInterval(
        of: period.calendarComponent,
        for: date
      )?.start
    else {
      return []
    }

    let starts = (0..<count).reversed().compactMap {
      calendar.date(byAdding: period.calendarComponent, value: -$0, to: currentStart)
    }
    let visibleStarts = Set(starts)
    var grouped: [Date: TokenUsageMetrics] = [:]

    for event in events {
      guard
        let start = calendar.dateInterval(
          of: period.calendarComponent,
          for: event.timestamp
        )?.start,
        visibleStarts.contains(start)
      else {
        continue
      }
      let previous = grouped[start, default: .zero]
      grouped[start] = TokenUsageMetrics(
        inputTokens: previous.inputTokens + event.inputTokens,
        outputTokens: previous.outputTokens + event.outputTokens
      )
    }

    return starts.map { start in
      let metrics = grouped[start, default: .zero]
      return TokenUsageChartBucket(
        startDate: start,
        inputTokens: metrics.inputTokens,
        outputTokens: metrics.outputTokens
      )
    }
  }
}
