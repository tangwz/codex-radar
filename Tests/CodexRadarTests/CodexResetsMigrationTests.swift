import Foundation
import Testing

@testable import CodexRadar

struct CodexResetsMigrationTests {
  @Test
  func watchExpirationDoesNotChangeTheAnnouncementRevision() throws {
    let document = try APIJSONCoding.makeDecoder().decode(
      CodexResetsStatus.self,
      from: publicStatus(record: publicRecord(), watch: publicWatch(), total: 1)
    )
    let active = document.forecast(now: publicAPINow, stale: false)
    let expired = document.forecast(now: publicAPINow.addingTimeInterval(3601), stale: false)
    #expect(active.status == .candidate)
    #expect(expired.status == .announced)
    #expect(active.historyRevision == expired.historyRevision)
    #expect(active.historyRevision.latestResetID == "observed-a")
    #expect(active.historyRevision.totalAnnouncements == 1)
  }

  @Test
  func defaultsToPublicAPIWithoutOwnedBackend() {
    #expect(
      ResetForecastService().currentURL.absoluteString == "https://codex-resets.com/api/v1/status")
    #expect(
      ResetHistoryService().historyURL.absoluteString == "https://codex-resets.com/api/v1/resets")
  }

  @Test
  func acceptsPublishedStatusEnvelopeAsAnnouncementNotCompletedReset() async throws {
    let timestamp = Date().ISO8601Format()
    let body = Data(
      """
      {"data":{"latest_reset":{"id":"observed-test","reset_type":"banked","announced_at":"\(timestamp)","text":"A banked reset was announced.","source":{"type":"observed"}},"active_watch":null,"stats":{"total":1,"last_reset_at":"\(timestamp)","days_since_last":0,"avg_interval_days":null}},"meta":{"api_version":"v1","generated_at":"\(timestamp)"}}
      """.utf8)
    let service = ResetForecastService(
      loader: HTTPDataLoader { request in
        (
          body,
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
      })
    guard case .updated(let forecast, _) = try await service.fetch(etag: nil) else {
      Issue.record("Expected a mapped public status response")
      return
    }
    #expect(forecast.status == .announced)
    #expect(forecast.timing == nil)
    #expect(forecast.sourceURL == nil)
    #expect(forecast.lastResetAt != nil)
  }
}
