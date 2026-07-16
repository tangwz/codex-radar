import Foundation

struct ResetPollingSchedule: Sendable {
  let jitter: @Sendable () -> Int

  var successDelay: Duration {
    .seconds(60 + min(10, max(-10, jitter())))
  }

  func failureDelay(consecutiveFailures: Int) -> Duration {
    let exponent = min(6, max(0, consecutiveFailures - 1))
    return .seconds(min(300, 5 * (1 << exponent)))
  }
}
