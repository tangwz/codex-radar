import Foundation
import Testing

@testable import CodexRadar

struct ResetNotificationPolicyTests {
  @Test
  func firstSignalEstablishesBaselineWithoutNotification() {
    let decision = ResetNotificationPolicy.decision(
      forecast: makeForecast(status: .announced, signalID: "signal-1"),
      hasBaseline: false,
      lastSignalID: nil
    )

    #expect(decision == .establishBaseline("signal-1"))
  }

  @Test
  func firstEmptyStateEstablishesEmptyBaseline() {
    let decision = ResetNotificationPolicy.decision(
      forecast: makeForecast(status: .monitoring),
      hasBaseline: false,
      lastSignalID: nil
    )

    #expect(decision == .establishBaseline(nil))
  }

  @Test
  func ignoresSameOrMissingSignalAfterBaseline() {
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .announced, signalID: "signal-1"),
        hasBaseline: true,
        lastSignalID: "signal-1"
      ) == .ignore
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .monitoring),
        hasBaseline: true,
        lastSignalID: "signal-1"
      ) == .ignore
    )
  }

  @Test(arguments: [ResetStatus.announced, .completed])
  func notifiesOnceForANewNotifiableSignal(_ status: ResetStatus) {
    let forecast = makeForecast(status: status, signalID: "signal-2")

    #expect(
      ResetNotificationPolicy.decision(
        forecast: forecast,
        hasBaseline: true,
        lastSignalID: "signal-1"
      ) == .notify("signal-2")
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: forecast,
        hasBaseline: true,
        lastSignalID: "signal-2"
      ) == .ignore
    )
  }

  @Test
  func suppressesStaleOrNonNotifiableSnapshots() {
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .announced, stale: true, signalID: "signal-2"),
        hasBaseline: true,
        lastSignalID: "signal-1"
      ) == .ignore
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .candidate, signalID: "signal-2"),
        hasBaseline: true,
        lastSignalID: "signal-1"
      ) == .ignore
    )
    #expect(
      ResetNotificationPolicy.decision(
        forecast: makeForecast(status: .monitoring, signalID: "signal-2"),
        hasBaseline: true,
        lastSignalID: "signal-1"
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
  }

  @Test
  func omitsNotificationCopyForCandidateMonitoringAndStale() {
    #expect(ResetNotificationPresentation(forecast: makeForecast(status: .candidate)) == nil)
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
