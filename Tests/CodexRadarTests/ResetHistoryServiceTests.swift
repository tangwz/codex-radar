import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryServiceTests {
  @Test
  func sendsTimeZoneAndYear() async throws {
    let recorder = HistoryRequestRecorder()
    let service = ResetHistoryService(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        return (Data(historyServiceJSON().utf8), historyResponse(status: 200, url: request.url!))
      }
    )

    _ = try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", year: 2026)
    let request = try #require(await recorder.request)
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))

    #expect(request.url?.path == "/v1/history")
    #expect(
      components.queryItems?.first(where: { $0.name == "time_zone" })?.value == "Asia/Shanghai"
    )
    #expect(components.queryItems?.first(where: { $0.name == "year" })?.value == "2026")
    #expect(request.timeoutInterval == 15)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
  }

  @Test(arguments: [
    (400, ResetHistoryServiceError.invalidRequest),
    (503, .unavailable),
    (500, .invalidResponse),
  ])
  func mapsHTTPFailures(_ status: Int, _ expectedError: ResetHistoryServiceError) async {
    let service = ResetHistoryService(
      loader: HTTPDataLoader { request in
        (Data(), historyResponse(status: status, url: request.url!))
      }
    )

    await #expect(throws: expectedError) {
      try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", year: 2026)
    }
  }

  @Test
  func rejectsMismatchedResponseTimeZoneOrYear() async {
    let mismatchedTimeZone = ResetHistoryService(
      loader: HTTPDataLoader { request in
        (
          Data(historyServiceJSON(timeZone: "UTC").utf8),
          historyResponse(status: 200, url: request.url!)
        )
      }
    )
    let mismatchedYear = ResetHistoryService(
      loader: HTTPDataLoader { request in
        (
          Data(historyServiceJSON(year: 2025).utf8),
          historyResponse(status: 200, url: request.url!)
        )
      }
    )

    await #expect(throws: ResetHistoryServiceError.invalidResponse) {
      try await mismatchedTimeZone.fetch(timeZoneIdentifier: "Asia/Shanghai", year: 2026)
    }
    await #expect(throws: ResetHistoryServiceError.invalidResponse) {
      try await mismatchedYear.fetch(timeZoneIdentifier: "Asia/Shanghai", year: 2026)
    }
  }

  @Test
  func rejectsInvalidRequestTimeZoneBeforeLoading() async {
    let service = ResetHistoryService(
      loader: HTTPDataLoader { _ in
        Issue.record("The loader should not be called for an invalid request.")
        return (Data(), URLResponse())
      }
    )

    await #expect(throws: ResetHistoryServiceError.invalidRequest) {
      try await service.fetch(timeZoneIdentifier: "Invalid/Zone", year: nil)
    }
  }

  @Test
  func mapsPlainURLResponseToInvalidResponse() async {
    let service = ResetHistoryService(
      loader: HTTPDataLoader { request in
        (
          Data(),
          URLResponse(
            url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        )
      }
    )

    await #expect(throws: ResetHistoryServiceError.invalidResponse) {
      try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", year: 2026)
    }
  }
}

private actor HistoryRequestRecorder {
  private(set) var request: URLRequest?

  func record(_ request: URLRequest) {
    self.request = request
  }
}

private func historyResponse(status: Int, url: URL) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func historyServiceJSON(timeZone: String = "Asia/Shanghai", year: Int = 2026) -> String {
  let months = resetHistoryMonthSummariesJSON(year: year, timeZoneIdentifier: timeZone)
  return """
    {
      "schema_version":"1.0",
      "generated_at":"2026-07-19T09:00:00Z",
      "time_zone":"\(timeZone)",
      "year":\(year),
      "available_years":[\(year)],
      "current":{
        "week":{"from":"\(year)-07-13T16:00:00Z","to":"\(year)-07-20T16:00:00Z","count":2},
        "month":{"from":"\(year)-06-30T16:00:00Z","to":"\(year)-07-31T16:00:00Z","count":6}
      },
      "months":[\(months)],
      "recent":[]
    }
    """
}
