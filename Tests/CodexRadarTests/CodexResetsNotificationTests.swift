import Foundation
import Testing
@testable import CodexRadar

@MainActor
struct CodexResetsNotificationTests {
  @Test
  func upgradeBaselineSuppressesExistingAnnouncementsAfterWatchExpires() async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let consumed = ConsumedResetSignalStore(defaults: defaults)
    consumed.establishBaseline(signalID: "legacy-backend-signal")
    var deliveries: [String] = []
    let service = ResetNotificationService(defaults: defaults, consumedSignalStore: consumed) { _, id in
      deliveries.append(id)
      return true
    }
    let document = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(), watch: publicWatch())
    )
    await service.observe(document.forecast(now: publicAPINow, stale: true))
    await service.observe(document.forecast(now: publicAPINow, stale: false))
    await service.observe(document.forecast(now: publicAPINow.addingTimeInterval(3601), stale: false))
    #expect(deliveries.isEmpty)

    let next = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(id: "new-event", at: "2026-09-07T10:00:00Z"))
    ).forecast(now: publicAPINow.addingTimeInterval(7201), stale: false)
    await service.observe(next)
    await service.observe(next)
    #expect(deliveries == ["codex-resets:reset:new-event"])
    #expect(ResetNotificationPresentation(forecast: next)?.body == .announcement)
    #expect(ResetForecastPresentation(forecast: next).timeDisplay == .none)
  }

  @Test
  func publicSourceStringsDistinguishAnnouncementsFromAccountQuota() {
    let english = Locale(identifier: "en_US")
    let chinese = Locale(identifier: "zh_Hans")
    #expect(CodexResetsCopy.text("all", locale: chinese) == "全部公告")
    #expect(CodexResetsCopy.text("regular", locale: english) == "Regular")
    #expect(CodexResetsCopy.text("announcementDisclaimer", locale: english).contains("not verified"))
    #expect(CodexResetsCopy.text("forecastDisclaimer", locale: chinese).contains("尚未确认"))
  }
}
