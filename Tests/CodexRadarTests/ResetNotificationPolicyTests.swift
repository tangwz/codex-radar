import Foundation
import Testing

@testable import CodexRadar

struct ResetNotificationPolicyTests {
  @MainActor
  @Test
  func suppressesCurrentSignalWhenMigratingAnExistingBaseline() async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "hasResetSignalBaseline")
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

    await service.observe(makeForecast(status: .candidate, signalID: "signal-1"))
    await service.observe(makeForecast(status: .candidate, signalID: "signal-2"))

    #expect(deliveredSignalIDs == ["signal-2"])
    #expect(consumedSignalStore.contains("signal-1"))
    #expect(consumedSignalStore.contains("signal-2"))
  }

  @MainActor
  @Test
  func suppressesCurrentSignalWhenRecoveringCorruptConsumedIDsWithoutLegacyID() async throws {
    try await assertCorruptConsumedIDsRecovery(legacySignalID: nil)
  }

  @MainActor
  @Test
  func suppressesCurrentSignalWhenRecoveringCorruptConsumedIDsWithLegacyID() async throws {
    try await assertCorruptConsumedIDsRecovery(legacySignalID: "legacy-signal")
  }

  @MainActor
  @Test
  func establishesBaselineWhenRecoveringCorruptConsumedIDs() async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("invalid".utf8), forKey: "consumedResetSignalIDs")
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

    await service.observe(makeForecast(status: .candidate, signalID: "signal-1"))
    await service.observe(makeForecast(status: .candidate, signalID: "signal-2"))

    #expect(deliveredSignalIDs == ["signal-2"])
    #expect(consumedSignalStore.hasBaseline)
    #expect(consumedSignalStore.contains("signal-1"))
    #expect(consumedSignalStore.contains("signal-2"))
  }

  @MainActor
  @Test
  func coalescesConcurrentObservationsForTheSameSignal() async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let consumedSignalStore = ConsumedResetSignalStore(defaults: defaults)
    consumedSignalStore.establishBaseline(signalID: "signal-1")
    let deliveryGate = DeliveryGate()
    let service = ResetNotificationService(
      defaults: defaults,
      consumedSignalStore: consumedSignalStore,
      deliverNotification: { _, _ in
        await deliveryGate.deliver()
      }
    )
    let forecast = makeForecast(status: .candidate, signalID: "signal-2")

    let firstObservation = Task { await service.observe(forecast) }
    await deliveryGate.waitUntilFirstDeliveryStarts()

    let secondObservation = Task { await service.observe(forecast) }
    await secondObservation.value

    #expect(await deliveryGate.deliveryCount == 1)

    await deliveryGate.releaseFirstDelivery(success: true)
    await firstObservation.value

    #expect(consumedSignalStore.contains("signal-2"))
  }

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

  @MainActor
  private func assertCorruptConsumedIDsRecovery(legacySignalID: String?) async throws {
    let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "hasResetSignalBaseline")
    defaults.set(Data("invalid".utf8), forKey: "consumedResetSignalIDs")
    if let legacySignalID {
      defaults.set(legacySignalID, forKey: "lastObservedResetSignalID")
    }
    let consumedSignalStore = ConsumedResetSignalStore(defaults: defaults)
    var deliveryCount = 0
    let service = ResetNotificationService(
      defaults: defaults,
      consumedSignalStore: consumedSignalStore,
      deliverNotification: { _, _ in
        deliveryCount += 1
        return true
      }
    )

    await service.observe(makeForecast(status: .candidate, signalID: "current-signal"))

    #expect(deliveryCount == 0)
    let expectedSignalIDs = Set([legacySignalID, "current-signal"].compactMap(\.self))
    #expect(consumedSignalStore.consumedSignalIDs == expectedSignalIDs)
    let data = try #require(defaults.data(forKey: "consumedResetSignalIDs"))
    #expect(try JSONDecoder().decode([String].self, from: data) == expectedSignalIDs.sorted())
  }
}

private actor DeliveryGate {
  private(set) var deliveryCount = 0
  private var firstDeliveryContinuation: CheckedContinuation<Bool, Never>?
  private var firstDeliveryStartedContinuations: [CheckedContinuation<Void, Never>] = []

  func deliver() async -> Bool {
    deliveryCount += 1
    guard deliveryCount == 1 else { return false }

    let startedContinuations = firstDeliveryStartedContinuations
    firstDeliveryStartedContinuations.removeAll()
    for continuation in startedContinuations {
      continuation.resume()
    }

    return await withCheckedContinuation { continuation in
      firstDeliveryContinuation = continuation
    }
  }

  func waitUntilFirstDeliveryStarts() async {
    guard deliveryCount == 0 else { return }
    await withCheckedContinuation { continuation in
      firstDeliveryStartedContinuations.append(continuation)
    }
  }

  func releaseFirstDelivery(success: Bool) {
    firstDeliveryContinuation?.resume(returning: success)
    firstDeliveryContinuation = nil
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
