import Foundation

struct TokenUsagePresentation {
  let metrics: TokenUsageMetrics
  let buckets: [TokenUsageChartBucket]

  init(snapshot: TokenUsageSnapshot?, period: TokenUsagePeriod) {
    metrics = snapshot?.metrics(for: period) ?? .zero
    buckets = snapshot?.buckets(for: period) ?? []
  }

  init(
    metrics: TokenUsageMetrics,
    buckets: [TokenUsageChartBucket]
  ) {
    self.metrics = metrics
    self.buckets = buckets
  }

  func nearestBucket(to date: Date) -> TokenUsageChartBucket? {
    buckets.min {
      abs($0.startDate.timeIntervalSince(date))
        < abs($1.startDate.timeIntervalSince(date))
    }
  }
}
