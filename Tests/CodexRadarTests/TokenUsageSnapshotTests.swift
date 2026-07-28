import Foundation
import Testing

@testable import CodexRadar

struct TokenUsageSnapshotTests {
  @Test
  func usesCurrentNaturalPeriodForMetricsInsteadOfAllHistory() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-07-15T12:00:00Z")
    let events = [
      event("2025-12-01T12:00:00Z", input: 1_000, output: 100),
      event("2026-07-01T12:00:00Z", input: 200, output: 20),
      event("2026-07-15T08:00:00Z", input: 30, output: 3),
    ]

    let snapshot = TokenUsageSnapshotBuilder.make(
      events: events,
      at: now,
      timeZone: timeZone
    )

    #expect(snapshot.metrics(for: .day) == TokenUsageMetrics(inputTokens: 30, outputTokens: 3))
    #expect(
      snapshot.metrics(for: .month)
        == TokenUsageMetrics(inputTokens: 230, outputTokens: 23)
    )
    #expect(
      snapshot.metrics(for: .year)
        == TokenUsageMetrics(inputTokens: 230, outputTokens: 23)
    )
  }

  @Test
  func createsContinuousWindowsAndFillsMissingPeriodsWithZero() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-07-15T12:00:00Z")
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [event("2026-07-13T08:00:00Z", input: 40, output: 4)],
      at: now,
      timeZone: timeZone
    )

    #expect(snapshot.dailyBuckets.count == 14)
    #expect(snapshot.monthlyBuckets.count == 12)
    #expect(snapshot.yearlyBuckets.count == 6)
    #expect(snapshot.dailyBuckets.suffix(3).map(\.totalTokens) == [44, 0, 0])
    #expect(snapshot.hasUsageData)
  }

  @Test
  func distinguishesNoUsageFromAZeroCurrentPeriod() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-07-15T12:00:00Z")
    let empty = TokenUsageSnapshotBuilder.make(events: [], at: now, timeZone: timeZone)
    let historical = TokenUsageSnapshotBuilder.make(
      events: [event("2020-01-01T00:00:00Z", input: 10, output: 1)],
      at: now,
      timeZone: timeZone
    )

    #expect(!empty.hasUsageData)
    #expect(historical.hasUsageData)
    #expect(historical.metrics(for: .day) == .zero)
  }

  @Test
  func aggregatesEventsIntoRequestedCalendarPeriods() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try date("2026-08-01T12:00:00Z")
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [
        event("2026-07-30T01:00:00Z", input: 100, output: 10),
        event("2026-07-31T01:00:00Z", input: 50, output: 5),
        event("2026-08-01T01:00:00Z", input: 25, output: 5),
      ],
      at: now,
      timeZone: timeZone
    )

    #expect(
      snapshot.dailyBuckets.filter { $0.totalTokens > 0 }.map(\.totalTokens) == [110, 55, 30])
    #expect(snapshot.monthlyBuckets.filter { $0.totalTokens > 0 }.map(\.totalTokens) == [165, 30])
    #expect(snapshot.yearlyBuckets.filter { $0.totalTokens > 0 }.map(\.totalTokens) == [195])
  }

  private func event(
    _ timestamp: String,
    input: Int,
    output: Int
  ) -> TokenUsageEvent {
    TokenUsageEvent(
      timestamp: ISO8601DateFormatter().date(from: timestamp)!,
      inputTokens: input,
      cachedInputTokens: 0,
      outputTokens: output
    )
  }

  private func date(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }
}
