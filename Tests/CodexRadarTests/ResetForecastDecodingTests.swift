import Foundation
import Testing

@testable import CodexRadar

struct ResetForecastDecodingTests {
  @Test
  func decodesCompleteAnnouncedResponse() throws {
    let forecast = try decode(
      """
      {
        "schema_version": "1.0",
        "monitored_at": "2026-07-16T01:00:00.000Z",
        "stale": false,
        "status": "announced",
        "recommended_action": "wait",
        "message": "Tibo announced a Codex reset.",
        "signal_id": "signal-123",
        "timing": {
          "kind": "exact",
          "at": "2026-07-16T02:00:00Z"
        },
        "source_url": "https://x.com/thsottiaux/status/1950000000000000000",
        "posts": [{
          "id": "1950000000000000000",
          "text": "Resetting Codex in one hour",
          "created_at": "2026-07-16T01:00:00.000Z",
          "url": "https://x.com/thsottiaux/status/1950000000000000000",
          "context": {
            "kind": "reply",
            "text": "Will you reset Codex usage?",
            "author_handle": "someone",
            "url": "https://x.com/someone/status/1949999999999999999"
          }
        }]
      }
      """
    )

    #expect(forecast.status == .announced)
    #expect(forecast.recommendedAction == .wait)
    #expect(forecast.signalID == "signal-123")
    #expect(forecast.timing?.kind == .exact)
    #expect(forecast.posts.count == 1)
    #expect(forecast.posts[0].context?.kind == .reply)
    #expect(forecast.posts[0].context?.authorHandle == "someone")
  }

  @Test
  func decodesMonitoringResponseWithoutOptionalFields() throws {
    let forecast = try decode(
      """
      {
        "schema_version": "1.0",
        "monitored_at": "2026-07-16T01:00:00Z",
        "stale": false,
        "status": "monitoring",
        "recommended_action": "none",
        "message": "Monitoring Tibo for reset signals.",
        "posts": []
      }
      """
    )

    #expect(forecast.signalID == nil)
    #expect(forecast.timing == nil)
    #expect(forecast.sourceURL == nil)
    #expect(forecast.posts.isEmpty)
  }

  @Test(arguments: [
    ("imminent", #"{"kind":"imminent"}"#),
    (
      "estimated",
      #"{"kind":"estimated","from":"2026-07-16T01:00:00Z","to":"2026-07-16T02:00:00.000Z"}"#
    ),
  ])
  func decodesSupportedTiming(_ name: String, _ timing: String) throws {
    let forecast = try decode(response(timing: timing))

    #expect(forecast.timing?.kind.rawValue == name)
  }

  @Test
  func decodesCompletedResponse() throws {
    let forecast = try decode(response(status: "completed", action: "use_now"))

    #expect(forecast.status == .completed)
    #expect(forecast.recommendedAction == .useNow)
  }

  @Test
  func distinguishesMissingNullAndKnownLastReset() throws {
    let missing = try decode(response())
    let none = try decode(response(lastResetField: #", "last_reset_at": null"#))
    let known = try decode(
      response(lastResetField: #", "last_reset_at": "2026-07-19T08:21:34Z""#)
    )

    #expect(missing.lastReset == .unavailable)
    #expect(none.lastReset == .none)
    guard case .resetAt(let resetAt) = known.lastReset else {
      Issue.record("Expected a known reset timestamp.")
      return
    }
    #expect(known.lastResetAt == resetAt)
  }

  @Test(arguments: [
    response(status: "surprise"),
    response(action: "later"),
    response(timing: #"{"kind":"sometime"}"#),
  ])
  func rejectsUnknownEnums(_ json: String) {
    #expect(throws: DecodingError.self) {
      try decode(json)
    }
  }

  @Test(arguments: [
    response(monitoredAt: "not-a-date"),
    response(timing: #"{"kind":"exact","at":"not-a-date"}"#),
    response(
      timing: #"{"kind":"exact","at":"2026-07-16T02:00:00Z","from":"2026-07-16T01:00:00Z"}"#),
    response(
      timing: #"{"kind":"estimated","from":"2026-07-16T03:00:00Z","to":"2026-07-16T02:00:00Z"}"#),
    response(timing: #"{"kind":"imminent","at":"2026-07-16T02:00:00Z"}"#),
  ])
  func rejectsInvalidDatesAndTimingShapes(_ json: String) {
    #expect(throws: DecodingError.self) {
      try decode(json)
    }
  }

  @Test
  func rejectsMoreThanFiveEvidencePosts() {
    let posts = (1...6).map { index in
      """
      {
        "id": "\(index)",
        "text": "Post \(index)",
        "created_at": "2026-07-16T01:00:00Z",
        "url": "https://x.com/thsottiaux/status/\(index)",
        "context": null
      }
      """
    }.joined(separator: ",")

    #expect(throws: DecodingError.self) {
      try decode(response(posts: "[\(posts)]"))
    }
  }

  private func decode(_ json: String) throws -> ResetForecast {
    try ResetForecast.decoder.decode(ResetForecast.self, from: Data(json.utf8))
  }

}

private func response(
  monitoredAt: String = "2026-07-16T01:00:00Z",
  status: String = "announced",
  action: String = "wait",
  timing: String? = nil,
  posts: String = "[]",
  lastResetField: String = ""
) -> String {
  let timingField = timing.map { ",\"timing\":\($0)" } ?? ""
  return """
    {
      "schema_version":"1.0",
      "monitored_at":"\(monitoredAt)",
      "stale":false,
      "status":"\(status)",
      "recommended_action":"\(action)",
      "message":"Status"
      \(timingField),
      "posts":\(posts)\(lastResetField)
    }
    """
}
