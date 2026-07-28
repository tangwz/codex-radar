import Foundation
import Testing

@testable import CodexRadar

struct TokenUsagePresentationTests {
  @Test
  func selectedPeriodControlsMetricsAndBuckets() throws {
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [
        TokenUsageEvent(
          timestamp: ISO8601DateFormatter().date(from: "2026-07-15T08:00:00Z")!,
          inputTokens: 100,
          cachedInputTokens: 90,
          outputTokens: 10
        )
      ],
      at: ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let daily = TokenUsagePresentation(snapshot: snapshot, period: .day)
    let monthly = TokenUsagePresentation(snapshot: snapshot, period: .month)

    #expect(daily.buckets.count == 14)
    #expect(monthly.buckets.count == 12)
    #expect(daily.metrics.totalTokens == 110)
    #expect(monthly.metrics.totalTokens == 110)
  }

  @Test
  func nearestBucketUsesTheSmallestAbsoluteTimeDistance() {
    let buckets = [
      bucket(at: 0),
      bucket(at: 100),
      bucket(at: 200),
    ]
    let presentation = TokenUsagePresentation(
      metrics: .zero,
      buckets: buckets
    )

    #expect(presentation.nearestBucket(to: Date(timeIntervalSince1970: 140))?.id == buckets[1].id)
    #expect(presentation.nearestBucket(to: Date(timeIntervalSince1970: 180))?.id == buckets[2].id)
  }

  private func bucket(at timestamp: TimeInterval) -> TokenUsageChartBucket {
    TokenUsageChartBucket(
      startDate: Date(timeIntervalSince1970: timestamp),
      inputTokens: 0,
      outputTokens: 0
    )
  }
}
