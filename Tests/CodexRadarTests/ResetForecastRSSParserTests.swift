import Foundation
import Testing

@testable import CodexRadar

struct ResetForecastRSSParserTests {
  @Test
  func parsesActiveOfficialWindowAndSource() throws {
    let xml = Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0"><channel><item>
        <title>Official window open: two Codex resets within 24 hours</title>
        <link>https://example.com/event</link>
        <pubDate>Tue, 14 Jul 2026 05:30:00 GMT</pubDate>
        <description><![CDATA[Tibo announced two resets within 24 hours. Source: https://x.com/thsottiaux/status/123]]></description>
      </item></channel></rss>
      """.utf8
    )
    let now = try parseDate("2026-07-14T12:00:00Z")
    let expectedReset = try parseDate("2026-07-15T05:30:00Z")

    let forecast = try ResetForecastRSSParser().parse(data: xml, now: now)

    #expect(forecast.isActive)
    #expect(forecast.predictedAt == expectedReset)
    #expect(forecast.sourceURL.absoluteString == "https://x.com/thsottiaux/status/123")
  }

  @Test
  func expiresPastOfficialWindowInsteadOfReportingStalePrediction() throws {
    let xml = Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0"><channel><item>
        <title>Official window open: Codex reset within 12 hours</title>
        <link>https://example.com/event</link>
        <pubDate>Tue, 14 Jul 2026 05:30:00 GMT</pubDate>
        <description>Source: https://x.com/thsottiaux/status/123</description>
      </item></channel></rss>
      """.utf8
    )
    let now = try parseDate("2026-07-15T12:00:00Z")

    let forecast = try ResetForecastRSSParser().parse(data: xml, now: now)

    #expect(!forecast.isActive)
    #expect(forecast.predictedAt == nil)
  }

  @Test
  func parsesChineseWindowMarkersWithoutDependingOnEnglishText() throws {
    let xml = Data(
      """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0"><channel><item>
        <title>\u{5F00}\u{542F}: 24\u{5C0F}\u{65F6}</title>
        <link>https://example.com/event</link>
        <pubDate>Tue, 14 Jul 2026 05:30:00 GMT</pubDate>
        <description>Source: https://x.com/thsottiaux/status/456</description>
      </item></channel></rss>
      """.utf8
    )
    let now = try parseDate("2026-07-14T06:00:00Z")

    let forecast = try ResetForecastRSSParser().parse(data: xml, now: now)

    #expect(forecast.isActive)
    #expect(forecast.sourceURL.absoluteString == "https://x.com/thsottiaux/status/456")
  }

  @Test
  func expiresActiveForecastAtItsDeadline() throws {
    let deadline = try parseDate("2026-07-15T05:30:00Z")
    let forecast = ResetForecast(
      isActive: true,
      predictedAt: deadline,
      announcedAt: try parseDate("2026-07-14T05:30:00Z"),
      title: "Active",
      summary: "Active",
      sourceURL: try #require(URL(string: "https://x.com/thsottiaux/status/789"))
    )

    #expect(forecast.expired(at: deadline.addingTimeInterval(-1)).isActive)
    #expect(!forecast.expired(at: deadline).isActive)
    #expect(forecast.expired(at: deadline).predictedAt == nil)
  }

  private func parseDate(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }
}
