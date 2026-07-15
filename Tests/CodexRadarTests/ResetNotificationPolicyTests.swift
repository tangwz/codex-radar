import Foundation
import Testing

@testable import CodexRadar

struct ResetNotificationPolicyTests {
  @Test
  func notifiesOnlyForANewActiveResetSource() {
    let active = ResetForecast(
      isActive: true,
      predictedAt: .now.addingTimeInterval(3_600),
      announcedAt: .now,
      title: "Official reset window",
      summary: "Reset incoming",
      sourceURL: URL(string: "https://x.com/thsottiaux/status/123")!
    )
    let inactive = ResetForecast(
      isActive: false,
      predictedAt: nil,
      announcedAt: .now,
      title: "Monitoring",
      summary: "No active window",
      sourceURL: active.sourceURL
    )

    #expect(ResetNotificationPolicy.shouldNotify(forecast: active, lastSourceURL: nil))
    #expect(
      !ResetNotificationPolicy.shouldNotify(
        forecast: active,
        lastSourceURL: active.sourceURL.absoluteString
      ))
    #expect(!ResetNotificationPolicy.shouldNotify(forecast: inactive, lastSourceURL: nil))
  }
}
