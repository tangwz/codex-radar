import Foundation
import Testing

@testable import CodexRadar

struct ResetForecastPresentationTests {
  @Test
  func mapsMonitoringAndCandidateWithoutCountdowns() {
    let monitoring = ResetForecastPresentation(
      forecast: presentationForecast(status: .monitoring, action: .none)
    )
    let candidate = ResetForecastPresentation(
      forecast: presentationForecast(status: .candidate, action: .watch)
    )

    #expect(monitoring.status == .monitoring)
    #expect(monitoring.action == .none)
    #expect(monitoring.timeDisplay == .none)
    #expect(candidate.status == .candidate)
    #expect(candidate.action == .watch)
    #expect(candidate.timeDisplay == .none)
  }

  @Test
  func mapsAnnouncedTimingWithoutInventingExactDates() {
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let from = at.addingTimeInterval(600)
    let to = at.addingTimeInterval(1_800)

    #expect(
      ResetForecastPresentation(
        forecast: presentationForecast(
          status: .announced,
          action: .wait,
          timing: ResetTiming(kind: .exact, at: at)
        )
      ).timeDisplay == .exact(at)
    )
    #expect(
      ResetForecastPresentation(
        forecast: presentationForecast(
          status: .announced,
          action: .wait,
          timing: ResetTiming(kind: .estimated, from: from, to: to)
        )
      ).timeDisplay == .estimated(from, to)
    )
    #expect(
      ResetForecastPresentation(
        forecast: presentationForecast(
          status: .announced,
          action: .wait,
          timing: ResetTiming(kind: .imminent)
        )
      ).timeDisplay == .imminent
    )
  }

  @Test
  func completedUsesNowActionWithoutOldCountdown() {
    let presentation = ResetForecastPresentation(
      forecast: presentationForecast(
        status: .completed,
        action: .useNow,
        timing: ResetTiming(
          kind: .exact,
          at: Date(timeIntervalSince1970: 1_700_000_000)
        )
      )
    )

    #expect(presentation.action == .useNow)
    #expect(presentation.timeDisplay == .none)
  }

  @Test
  func staleOverridesActionAndCountdownButPreservesEvidenceLink() {
    let sourceURL = URL(string: "https://x.com/thsottiaux/status/1")!
    let presentation = ResetForecastPresentation(
      forecast: presentationForecast(
        status: .announced,
        action: .wait,
        stale: true,
        timing: ResetTiming(
          kind: .exact,
          at: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        sourceURL: sourceURL
      )
    )

    #expect(presentation.stale)
    #expect(presentation.action == .unknown)
    #expect(presentation.timeDisplay == .none)
    #expect(presentation.sourceURL == sourceURL)
  }

  @Test
  func missingSourceURLRemainsAbsent() {
    let presentation = ResetForecastPresentation(
      forecast: presentationForecast(status: .monitoring, action: .none)
    )

    #expect(presentation.sourceURL == nil)
  }
}

private func presentationForecast(
  status: ResetStatus,
  action: RecommendedAction,
  stale: Bool = false,
  timing: ResetTiming? = nil,
  sourceURL: URL? = nil
) -> ResetForecast {
  ResetForecast(
    schemaVersion: "1.0",
    monitoredAt: Date(timeIntervalSince1970: 1_700_000_000),
    stale: stale,
    status: status,
    recommendedAction: action,
    message: "Status",
    signalID: nil,
    timing: timing,
    sourceURL: sourceURL,
    posts: []
  )
}
