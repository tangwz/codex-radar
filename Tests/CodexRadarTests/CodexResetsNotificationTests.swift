import Foundation
import Testing

@testable import CodexRadar

@MainActor
struct CodexResetsNotificationTests {
  @Test(arguments: [false, true], [false, true])
  func observedAnnouncementDoesNotNotifyAfterNewerWatchExpires(
    restartBeforeExpiry: Bool, watchDeliverySucceeds: Bool
  ) async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstObservation = publicAPINow.addingTimeInterval(-7200)
    var deliveries: [String] = []
    let deliver: ResetNotificationService.DeliverNotification = { _, id in
      deliveries.append(id)
      return id.contains(":watch:") ? watchDeliverySucceeds : true
    }
    let service = ResetNotificationService(
      defaults: defaults, now: { firstObservation }, deliverNotification: deliver
    )
    let initial = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus()
    )
    await service.observe(initial.forecast(now: firstObservation, stale: false))
    let document = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(), watch: publicWatch())
    )
    let active = document.forecast(now: publicAPINow, stale: false)
    await service.observe(active)
    await service.observe(active)
    let watchAttempts = Array(
      repeating: "codex-resets:watch:https://x.com/example/status/123",
      count: watchDeliverySucceeds ? 1 : 2
    )
    #expect(deliveries == watchAttempts)

    let observer =
      restartBeforeExpiry
      ? ResetNotificationService(
        defaults: defaults, now: { firstObservation }, deliverNotification: deliver
      ) : service
    let expired = document.forecast(now: publicAPINow.addingTimeInterval(3601), stale: false)
    #expect(expired.status == .announced)
    await observer.observe(expired)
    #expect(deliveries == watchAttempts)

    let next = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(
        record: publicRecord(id: "later-announcement", at: "2026-09-07T09:01:00Z"),
        watch: publicWatch()
      )
    ).forecast(now: publicAPINow.addingTimeInterval(3720), stale: false)
    await observer.observe(next)
    #expect(deliveries == watchAttempts + ["codex-resets:reset:later-announcement"])
  }

  @Test
  func alreadyConsumedWatchStillConsumesItsAccompanyingAnnouncement() async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstObservation = publicAPINow.addingTimeInterval(-7200)
    var deliveries: [String] = []
    let service = ResetNotificationService(defaults: defaults, now: { firstObservation }) { _, id in
      deliveries.append(id)
      return true
    }
    let initial = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus()
    )
    await service.observe(initial.forecast(now: firstObservation, stale: false))
    let watch = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus(watch: publicWatch())
    )
    await service.observe(watch.forecast(now: publicAPINow, stale: false))
    let document = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(), watch: publicWatch())
    )
    await service.observe(document.forecast(now: publicAPINow, stale: false))
    await service.observe(
      document.forecast(now: publicAPINow.addingTimeInterval(3601), stale: false))
    #expect(deliveries == ["codex-resets:watch:https://x.com/example/status/123"])
  }

  @Test
  func staleWatchDoesNotConsumeItsAccompanyingAnnouncement() async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstObservation = publicAPINow.addingTimeInterval(-7200)
    var deliveries: [String] = []
    let service = ResetNotificationService(defaults: defaults, now: { firstObservation }) { _, id in
      deliveries.append(id)
      return true
    }
    let initial = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus()
    )
    await service.observe(initial.forecast(now: firstObservation, stale: false))
    let document = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(), watch: publicWatch())
    )
    await service.observe(document.forecast(now: publicAPINow, stale: true))
    #expect(deliveries.isEmpty)
    await service.observe(
      document.forecast(now: publicAPINow.addingTimeInterval(3601), stale: false))
    #expect(deliveries == ["codex-resets:reset:observed-a"])
  }

  @Test
  func cachedInitialSnapshotDoesNotNotifyAnnouncementsFromBeforeFirstObservation() async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let firstObservation = publicAPINow
    var deliveries: [String] = []
    let service = ResetNotificationService(defaults: defaults, now: { firstObservation }) { _, id in
      deliveries.append(id)
      return true
    }
    let initial = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(generatedAt: firstObservation.addingTimeInterval(-600).ISO8601Format())
    )
    await service.observe(initial.forecast(now: firstObservation, stale: false))

    let hidden = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(
        record: publicRecord(
          id: "before-launch", at: firstObservation.addingTimeInterval(-300).ISO8601Format()
        ))
    )
    await service.observe(
      hidden.forecast(now: firstObservation.addingTimeInterval(600), stale: false))
    #expect(deliveries.isEmpty)

    let newAnnouncement = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(
        record: publicRecord(
          id: "after-launch", at: firstObservation.addingTimeInterval(300).ISO8601Format()
        ))
    )
    let next = newAnnouncement.forecast(now: firstObservation.addingTimeInterval(600), stale: false)
    await service.observe(next)
    await service.observe(next)
    let restarted = ResetNotificationService(defaults: defaults, now: { firstObservation }) {
      _, id in
      deliveries.append(id)
      return true
    }
    await restarted.observe(next)
    #expect(deliveries == ["codex-resets:reset:after-launch"])
  }

  @Test
  func cachedInitialSnapshotDoesNotNotifyForecastsFromBeforeFirstObservation() async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var deliveries: [String] = []
    let service = ResetNotificationService(defaults: defaults, now: { publicAPINow }) { _, id in
      deliveries.append(id)
      return true
    }
    let initial = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus(generatedAt: "2026-09-07T07:00:00Z")
    )
    await service.observe(initial.forecast(now: publicAPINow, stale: false))
    let hiddenWatch = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus(watch: publicWatch())
    )
    await service.observe(hiddenWatch.forecast(now: publicAPINow, stale: false))
    #expect(deliveries.isEmpty)

    let newWatch = publicWatch()
      .replacingOccurrences(of: "2026-09-07T07:30:00Z", with: "2026-09-07T08:01:00Z")
      .replacingOccurrences(of: "/status/123", with: "/status/456")
    let next = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self, from: publicStatus(watch: newWatch)
    ).forecast(now: publicAPINow.addingTimeInterval(120), stale: false)
    await service.observe(next)
    #expect(deliveries == ["codex-resets:watch:https://x.com/example/status/456"])
  }

  @Test
  func upgradeBaselineSuppressesExistingAnnouncementsAfterWatchExpires() async throws {
    let suite = "CodexResetsNotificationTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let consumed = ConsumedResetSignalStore(defaults: defaults)
    consumed.establishBaseline(signalID: "legacy-backend-signal")
    var deliveries: [String] = []
    let service = ResetNotificationService(
      defaults: defaults, consumedSignalStore: consumed, now: { publicAPINow }
    ) { _, id in
      deliveries.append(id)
      return true
    }
    let document = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(), watch: publicWatch())
    )
    await service.observe(document.forecast(now: publicAPINow, stale: true))
    await service.observe(document.forecast(now: publicAPINow, stale: false))
    await service.observe(
      document.forecast(now: publicAPINow.addingTimeInterval(3601), stale: false))
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
    #expect(
      CodexResetsCopy.text("announcementDisclaimer", locale: english).contains("not verified"))
    #expect(CodexResetsCopy.text("forecastDisclaimer", locale: chinese).contains("尚未确认"))
  }
}
