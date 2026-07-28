import CoreGraphics
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

  @Test
  func hoverStateSelectsOnlyInsideThePlotFrame() {
    let buckets = [bucket(at: 0), bucket(at: 100), bucket(at: 200)]
    let presentation = TokenUsagePresentation(metrics: .zero, buckets: buckets)
    let plotFrame = CGRect(x: 10, y: 10, width: 100, height: 100)
    var hoverState = TokenUsageHoverState()

    hoverState.selectNearestBucket(
      at: CGPoint(x: 60, y: 60),
      in: plotFrame,
      date: Date(timeIntervalSince1970: 140),
      presentation: presentation
    )
    #expect(hoverState.selectedBucketID == buckets[1].id)

    for location in [
      CGPoint(x: 9, y: 60),
      CGPoint(x: 111, y: 60),
      CGPoint(x: 60, y: 9),
      CGPoint(x: 60, y: 111),
    ] {
      hoverState.selectNearestBucket(
        at: CGPoint(x: 60, y: 60),
        in: plotFrame,
        date: Date(timeIntervalSince1970: 140),
        presentation: presentation
      )
      hoverState.selectNearestBucket(
        at: location,
        in: plotFrame,
        date: Date(timeIntervalSince1970: 140),
        presentation: presentation
      )
      #expect(hoverState.selectedBucketID == nil)
    }
  }

  @Test
  func hoverStateClearsSelectionWhenThePeriodChanges() {
    let snapshot = snapshot(generatedAt: 0, bucket: bucket(at: 100))
    var hoverState = TokenUsageHoverState()

    hoverState.updateContext(snapshot: snapshot, period: .day)
    hoverState.selectNearestBucket(
      at: CGPoint(x: 20, y: 20),
      in: CGRect(x: 10, y: 10, width: 100, height: 100),
      date: Date(timeIntervalSince1970: 100),
      presentation: TokenUsagePresentation(snapshot: snapshot, period: .day)
    )
    hoverState.updateContext(snapshot: snapshot, period: .month)

    #expect(hoverState.selectedBucketID == nil)
  }

  @Test
  func hoverStateClearsSelectionWhenTheSnapshotChangesWithTheSameBucketDate() {
    let originalBucket = bucket(at: 100)
    let replacementBucket = TokenUsageChartBucket(
      startDate: originalBucket.startDate,
      inputTokens: 20,
      outputTokens: 2
    )
    let originalSnapshot = snapshot(generatedAt: 0, bucket: originalBucket)
    let replacementSnapshot = snapshot(generatedAt: 1, bucket: replacementBucket)
    var hoverState = TokenUsageHoverState()

    hoverState.updateContext(snapshot: originalSnapshot, period: .day)
    hoverState.selectNearestBucket(
      at: CGPoint(x: 20, y: 20),
      in: CGRect(x: 10, y: 10, width: 100, height: 100),
      date: originalBucket.startDate,
      presentation: TokenUsagePresentation(snapshot: originalSnapshot, period: .day)
    )
    hoverState.updateContext(snapshot: replacementSnapshot, period: .day)

    #expect(originalBucket.id == replacementBucket.id)
    #expect(hoverState.selectedBucketID == nil)

    hoverState.updateContext(snapshot: originalSnapshot, period: .day)
    hoverState.selectNearestBucket(
      at: CGPoint(x: 20, y: 20),
      in: CGRect(x: 10, y: 10, width: 100, height: 100),
      date: originalBucket.startDate,
      presentation: TokenUsagePresentation(snapshot: originalSnapshot, period: .day)
    )
    hoverState.updateContext(snapshot: nil, period: .day)
    #expect(hoverState.selectedBucketID == nil)

    hoverState.updateContext(snapshot: originalSnapshot, period: .day)
    hoverState.selectNearestBucket(
      at: CGPoint(x: 20, y: 20),
      in: CGRect(x: 10, y: 10, width: 100, height: 100),
      date: originalBucket.startDate,
      presentation: TokenUsagePresentation(snapshot: originalSnapshot, period: .day)
    )
    hoverState.updateContext(snapshot: emptySnapshot(), period: .day)
    #expect(hoverState.selectedBucketID == nil)
  }

  private func bucket(at timestamp: TimeInterval) -> TokenUsageChartBucket {
    TokenUsageChartBucket(
      startDate: Date(timeIntervalSince1970: timestamp),
      inputTokens: 0,
      outputTokens: 0
    )
  }

  private func snapshot(
    generatedAt timestamp: TimeInterval,
    bucket: TokenUsageChartBucket
  ) -> TokenUsageSnapshot {
    TokenUsageSnapshot(
      schemaVersion: TokenUsageCacheVersion.schema,
      parserVersion: TokenUsageCacheVersion.parser,
      generatedAt: Date(timeIntervalSince1970: timestamp),
      timeZoneIdentifier: "UTC",
      hasUsageData: true,
      dailyBuckets: [bucket],
      monthlyBuckets: [bucket],
      yearlyBuckets: [bucket]
    )
  }

  private func emptySnapshot() -> TokenUsageSnapshot {
    TokenUsageSnapshot(
      schemaVersion: TokenUsageCacheVersion.schema,
      parserVersion: TokenUsageCacheVersion.parser,
      generatedAt: Date(timeIntervalSince1970: 2),
      timeZoneIdentifier: "UTC",
      hasUsageData: false,
      dailyBuckets: [],
      monthlyBuckets: [],
      yearlyBuckets: []
    )
  }
}
