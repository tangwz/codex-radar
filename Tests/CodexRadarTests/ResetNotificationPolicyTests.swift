import Foundation
import Testing

@testable import CodexRadar

struct ResetNotificationPolicyTests {
  @MainActor
  @Test
  func retriesUnconsumedCandidateUntilDeliverySucceeds() async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let consumedSignalStore = ConsumedResetSignalStore(defaults: defaults)

    var deliveryResults = [false, true]
    var deliveredSignalIDs: [String] = []
    let service = ResetNotificationService(
      defaults: defaults,
      consumedSignalStore: consumedSignalStore,
      deliverNotification: { _, signalID in
        deliveredSignalIDs.append(signalID)
        return deliveryResults.removeFirst()
      }
    )

    await service.observe(makeForecast(status: .monitoring))
    let forecast = makeForecast(status: .candidate, signalID: "signal-2")

    await service.observe(forecast)
    #expect(!consumedSignalStore.contains("signal-2"))

    await service.observe(forecast)
    await service.observe(forecast)

    #expect(deliveredSignalIDs == ["signal-2", "signal-2"])
    #expect(consumedSignalStore.contains("signal-2"))
  }

  @MainActor
  @Test
  func consumesDeliveredCandidateOnlyOnce() async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let consumedSignalStore = ConsumedResetSignalStore(defaults: defaults)

    var deliveredSignalIDs: [String] = []
    let service = ResetNotificationService(
      defaults: defaults,
      consumedSignalStore: consumedSignalStore,
      deliverNotification: { _, signalID in
        deliveredSignalIDs.append(signalID)
        return true
      }
    )

    await service.observe(makeForecast(status: .monitoring))
    let forecast = makeForecast(status: .candidate, signalID: "signal-2")

    await service.observe(forecast)
    await service.observe(forecast)

    #expect(deliveredSignalIDs == ["signal-2"])
    #expect(consumedSignalStore.contains("signal-2"))
  }

  @MainActor
  @Test
  func doesNotRedeliverConsumedCandidateAfterAnotherSignal() async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let consumedSignalStore = ConsumedResetSignalStore(defaults: defaults)

    var deliveredSignalIDs: [String] = []
    let service = ResetNotificationService(
      defaults: defaults,
      consumedSignalStore: consumedSignalStore,
      deliverNotification: { _, signalID in
        deliveredSignalIDs.append(signalID)
        return true
      }
    )

    await service.observe(makeForecast(status: .candidate, signalID: "signal-a"))
    await service.observe(makeForecast(status: .candidate, signalID: "signal-b"))
    await service.observe(makeForecast(status: .candidate, signalID: "signal-a"))

    #expect(deliveredSignalIDs == ["signal-b"])
    #expect(consumedSignalStore.contains("signal-a"))
    #expect(consumedSignalStore.contains("signal-b"))
  }

  @Test
  func firstSignalEstablishesBaselineWithoutNotification() {
    let decision = ResetNotificationPolicy.decision(
      forecast: makeForecast(status: .announced, signalID: "signal-1"),
      hasBaseline: false,
      consumedSignalIDs: []
    )

    #expect(decision == .establishBaseline("signal-1"))
  }

  @Test
  func firstEmptyStateEstablishesEmptyBaseline() {
    let decision = ResetNotificationPolicy.decision(
      forecast: makeForecast(status: .monitoring),
      hasBaseline: false,
      consumedSignalIDs: []
    )

    #expect(decision == .establishBaseline(nil))
  }

  @Test
  func ignoresConsumedOrMissingSignalAfterBaseline() {
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .announced, signalID: "signal-1"),
        hasBaseline: true,
        consumedSignalIDs: ["signal-1"]
      ) == .ignore
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .monitoring),
        hasBaseline: true,
        consumedSignalIDs: ["signal-1"]
      ) == .ignore
    )
  }

  @Test(arguments: [ResetStatus.candidate, .announced, .completed])
  func notifiesOnceForANewNotifiableSignal(_ status: ResetStatus) {
    let forecast = makeForecast(status: status, signalID: "signal-2")

    #expect(
      ResetNotificationPolicy.decision(
        forecast: forecast,
        hasBaseline: true,
        consumedSignalIDs: ["signal-1"]
      ) == .notify("signal-2")
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: forecast,
        hasBaseline: true,
        consumedSignalIDs: ["signal-2"]
      ) == .ignore
    )
  }

  @Test
  func ignoresPreviouslyConsumedSignalAfterAnotherSignal() {
    let decision = ResetNotificationPolicy.decision(
      forecast: makeForecast(status: .candidate, signalID: "signal-a"),
      hasBaseline: true,
      consumedSignalIDs: ["signal-a", "signal-b"]
    )

    #expect(decision == .ignore)
  }

  @Test
  func suppressesStaleOrNonNotifiableSnapshots() {
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .announced, stale: true, signalID: "signal-2"),
        hasBaseline: true,
        consumedSignalIDs: ["signal-1"]
      ) == .ignore
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .candidate, signalID: "signal-2"),
        hasBaseline: true,
        consumedSignalIDs: ["signal-2"]
      ) == .ignore
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .monitoring, signalID: "signal-2"),
        hasBaseline: true,
        consumedSignalIDs: ["signal-1"]
      ) == .ignore
    )
  }

  @Test
  func mapsNotificationCopyFromCanonicalStatusAndTiming() throws {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let from = at.addingTimeInterval(600)
    let to = at.addingTimeInterval(1_800)

    #expect(
      ResetNotificationPresentation(forecast: makeForecast(
        status: .announced,
        timing: ResetTiming(kind: .exact, at: at)
      ))?.body == .exact(at)
    )
    #expect(
      ResetNotificationPresentation(forecast: makeForecast(
        status: .announced,
        timing: ResetTiming(kind: .estimated, from: from, to: to)
      ))?.body == .estimated(from, to)
    )
    #expect(
      ResetNotificationPresentation(forecast: makeForecast(
        status: .announced,
        timing: ResetTiming(kind: .imminent)
      ))?.body == .imminent
    )
    #expect(
      ResetNotificationPresentation(forecast: makeForecast(status: .completed))?.body == .completed
    )
    #expect(
      ResetNotificationPresentation(forecast: makeForecast(status: .candidate))?.body == .candidate
    )
  }

  @Test
  func omitsNotificationCopyForMonitoringAndStale() {
    #expect(ResetNotificationPresentation(forecast: makeForecast(status: .monitoring)) == nil)
    #expect(
      ResetNotificationPresentation(
        forecast: makeForecast(status: .announced, stale: true)
      ) == nil
    )
  }
}

private func makeForecast(
  status: ResetStatus,
  stale: Bool = false,
  signalID: String? = nil,
  timing: ResetTiming? = nil
) -> ResetForecast {
  ResetForecast(
    schemaVersion: "1.0",
    monitoredAt: Date(timeIntervalSince1970: 1_700_000_000),
    stale: stale,
    status: status,
    recommendedAction: .none,
    message: "Status",
    signalID: signalID,
    timing: timing,
    sourceURL: nil,
    posts: []
  )
}
