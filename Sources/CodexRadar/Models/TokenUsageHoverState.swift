import CoreGraphics
import Foundation

struct TokenUsageHoverState {
  private struct Context: Equatable {
    let snapshot: TokenUsageSnapshot?
    let period: TokenUsagePeriod
  }

  private var context: Context?
  private(set) var selectedBucketID: Date?

  mutating func updateContext(
    snapshot: TokenUsageSnapshot?,
    period: TokenUsagePeriod
  ) {
    let updatedContext = Context(snapshot: snapshot, period: period)
    guard updatedContext != context else { return }

    context = updatedContext
    clear()
  }

  func contains(_ location: CGPoint, in plotFrame: CGRect) -> Bool {
    plotFrame.contains(location)
  }

  mutating func selectNearestBucket(
    at location: CGPoint,
    in plotFrame: CGRect,
    date: Date?,
    presentation: TokenUsagePresentation
  ) {
    guard contains(location, in: plotFrame), let date else {
      clear()
      return
    }

    selectedBucketID = presentation.nearestBucket(to: date)?.id
  }

  mutating func clear() {
    selectedBucketID = nil
  }
}
