import Foundation
import Testing

@testable import CodexRadar

struct ResetForecastServiceTests {
  @Test
  func usesCurrentEndpointTimeoutAndConditionalETag() async throws {
    let recorder = RequestRecorder()
    let service = ResetForecastService(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        return (Data(), response(status: 304, url: request.url!))
      }
    )

    _ = try await service.fetch(etag: #""signal-1""#)
    let request = try #require(await recorder.request)

    #expect(service.currentURL.absoluteString == "https://codexradar.com/v1/current")
    #expect(request.timeoutInterval == 15)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == #""signal-1""#)
  }

  @Test
  func decodesUpdatedForecastAndReturnsResponseETag() async throws {
    let service = ResetForecastService(
      loader: HTTPDataLoader { request in
        (
          Data(validCurrentJSON.utf8),
          response(
            status: 200,
            url: request.url!,
            headers: ["ETag": #""revision-2""#]
          )
        )
      }
    )

    let result = try await service.fetch(etag: nil)

    guard case .updated(let forecast, let etag) = result else {
      Issue.record("Expected an updated forecast.")
      return
    }
    #expect(forecast.status == .monitoring)
    #expect(etag == #""revision-2""#)
  }

  @Test
  func treatsNotModifiedAsSuccessWithoutDecodingBody() async throws {
    let service = ResetForecastService(
      loader: HTTPDataLoader { request in
        (Data("not-json".utf8), response(status: 304, url: request.url!))
      }
    )

    #expect(try await service.fetch(etag: nil) == .notModified)
  }

  @Test
  func mapsNotInitializedResponseToDedicatedError() async throws {
    let contract = try Data(contentsOf: notInitializedContractURL)
    let service = ResetForecastService(
      loader: HTTPDataLoader { request in
        (
          contract,
          response(status: 503, url: request.url!)
        )
      }
    )

    await #expect(throws: ResetForecastServiceError.notInitialized) {
      try await service.fetch(etag: nil)
    }
    #expect(
      ResetForecastServiceError.notInitialized.errorDescription
        == "Reset status is not available yet."
    )
  }

  @Test
  func rejectsOtherHTTPAndNonHTTPResponses() async {
    let httpService = ResetForecastService(
      loader: HTTPDataLoader { request in
        (Data(), response(status: 500, url: request.url!))
      }
    )
    let nonHTTPService = ResetForecastService(
      loader: HTTPDataLoader { request in
        (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
      }
    )

    await #expect(throws: ResetForecastServiceError.invalidResponse) {
      try await httpService.fetch(etag: nil)
    }
    await #expect(throws: ResetForecastServiceError.invalidResponse) {
      try await nonHTTPService.fetch(etag: nil)
    }
  }

  @Test
  func propagatesJSONDecodingErrors() async {
    let service = ResetForecastService(
      loader: HTTPDataLoader { request in
        (Data("not-json".utf8), response(status: 200, url: request.url!))
      }
    )

    await #expect(throws: DecodingError.self) {
      try await service.fetch(etag: nil)
    }
  }
}

private actor RequestRecorder {
  private(set) var request: URLRequest?

  func record(_ request: URLRequest) {
    self.request = request
  }
}

private let notInitializedContractURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("contracts/v1-current-not-initialized.json")

private let validCurrentJSON = """
{
  "schema_version": "1.0",
  "monitored_at": "2026-07-16T01:00:00Z",
  "stale": false,
  "status": "monitoring",
  "recommended_action": "none",
  "message": "Monitoring.",
  "posts": []
}
"""

private func response(
  status: Int,
  url: URL,
  headers: [String: String]? = nil
) -> HTTPURLResponse {
  HTTPURLResponse(
    url: url,
    statusCode: status,
    httpVersion: "HTTP/1.1",
    headerFields: headers
  )!
}
