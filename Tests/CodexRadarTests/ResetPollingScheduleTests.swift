import Foundation
import Testing

@testable import CodexRadar

struct ResetPollingScheduleTests {
  @Test(arguments: [(7, 67), (99, 70), (-99, 50)])
  func successDelayUsesOneMinutePlusBoundedJitter(_ jitter: Int, _ seconds: Int) {
    let schedule = ResetPollingSchedule(jitter: { jitter })

    #expect(schedule.successDelay == .seconds(seconds))
  }

  @Test
  func failureDelayExponentiallyBacksOffAndCapsAtFiveMinutes() {
    let schedule = ResetPollingSchedule(jitter: { 0 })

    #expect(schedule.failureDelay(consecutiveFailures: 1) == .seconds(5))
    #expect(schedule.failureDelay(consecutiveFailures: 2) == .seconds(10))
    #expect(schedule.failureDelay(consecutiveFailures: 7) == .seconds(300))
    #expect(schedule.failureDelay(consecutiveFailures: 20) == .seconds(300))
  }
}
