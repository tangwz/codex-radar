import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryServiceTests {
  @Test(arguments: [
    (ResetHistoryRange.threeMonths, "3m"),
    (ResetHistoryRange.sixMonths, nil),
    (.twelveMonths, "12m"),
    (.all, "all"),
  ])
  func sendsNormalizedRange(
    _ range: ResetHistoryRange,
    _ expectedQueryValue: String?
  ) async throws {
    let recorder = HistoryRequestRecorder()
    let service = ResetHistoryService(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        return (
          Data(historyServiceJSON(range: range).utf8),
          historyResponse(status: 200, url: request.url!)
        )
      }
    )

    _ = try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", range: range)
    let request = try #require(await recorder.request)
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))

    #expect(request.url?.path == "/v1/history")
    #expect(
      components.queryItems?.first(where: { $0.name == "time_zone" })?.value == "Asia/Shanghai"
    )
    #expect(
      components.queryItems?.first(where: { $0.name == "range" })?.value == expectedQueryValue)
    #expect(components.queryItems?.contains(where: { $0.name == "year" }) == false)
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
      try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", range: .sixMonths)
    }
  }

  @Test
  func rejectsMismatchedResponseTimeZoneOrRange() async {
    let mismatchedTimeZone = ResetHistoryService(
      loader: HTTPDataLoader { request in
        (
          Data(historyServiceJSON(timeZone: "UTC", range: .sixMonths).utf8),
          historyResponse(status: 200, url: request.url!)
        )
      }
    )
    let mismatchedRange = ResetHistoryService(
      loader: HTTPDataLoader { request in
        (
          Data(historyServiceJSON(range: .twelveMonths).utf8),
          historyResponse(status: 200, url: request.url!)
        )
      }
    )

    await #expect(throws: ResetHistoryServiceError.invalidResponse) {
      try await mismatchedTimeZone.fetch(timeZoneIdentifier: "Asia/Shanghai", range: .sixMonths)
    }
    await #expect(throws: ResetHistoryServiceError.invalidResponse) {
      try await mismatchedRange.fetch(timeZoneIdentifier: "Asia/Shanghai", range: .sixMonths)
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
      try await service.fetch(timeZoneIdentifier: "Invalid/Zone", range: .sixMonths)
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
      try await service.fetch(timeZoneIdentifier: "Asia/Shanghai", range: .sixMonths)
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

private func historyServiceJSON(
  timeZone: String = "Asia/Shanghai",
  range: ResetHistoryRange = .sixMonths
) -> String {
  let monthCount = range.fixedMonthCount ?? 6
  let startYear = range == .twelveMonths ? 2025 : 2026
  let startMonth: Int
  switch range {
  case .threeMonths:
    startMonth = 5
  case .twelveMonths:
    startMonth = 8
  case .sixMonths, .all:
    startMonth = 2
  }
  return resetHistoryJSON(
    range: range.rawValue,
    startYear: startYear,
    startMonth: startMonth,
    monthCount: monthCount,
    timeZoneIdentifier: timeZone
  )
}
