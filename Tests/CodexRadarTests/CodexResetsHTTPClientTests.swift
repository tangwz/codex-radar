import Foundation
import Testing

@testable import CodexRadar

struct CodexResetsHTTPClientTests {
  @Test(arguments: [nil, "30", "7200"] as [String?])
  func accountsForApparentAgeAndAgeHeader(_ age: String?) async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let client = CodexResetsHTTPClient(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        var headers = [
          "Cache-Control": "max-age=14400",
          "Date": "Mon, 07 Sep 2026 05:00:00 GMT",
        ]
        headers["Age"] = age
        return (publicStatus(), publicResponse(request, headers: headers))
      }, now: { clock.now() })

    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    clock.advance(3599)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 1)
    clock.advance(1)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 2)
  }

  @Test
  func includesRequestDelayWhenAgeExceedsApparentAge() async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let client = CodexResetsHTTPClient(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        clock.advance(10)
        return (
          publicStatus(),
          publicResponse(
            request,
            headers: [
              "Cache-Control": "max-age=60", "Age": "30",
              "Date": "Mon, 07 Sep 2026 08:00:00 GMT",
            ])
        )
      }, now: { clock.now() })

    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    clock.advance(19)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 1)
    clock.advance(1)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 2)
  }

  @Test
  func retainsOriginalMaxAgeWhen304OmitsCacheControl() async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let client = CodexResetsHTTPClient(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        if await recorder.requests.count == 1 {
          return (
            publicStatus(),
            publicResponse(
              request,
              headers: [
                "Cache-Control": "max-age=60", "Age": "30", "ETag": "status-1",
              ])
          )
        }
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "status-1")
        return (
          Data(),
          publicResponse(
            request, status: 304,
            headers: [
              "Date": "Mon, 07 Sep 2026 08:00:30 GMT"
            ])
        )
      }, now: { clock.now() })

    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    clock.advance(30)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    clock.advance(59)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 2)
    clock.advance(1)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 3)
  }

  @Test(arguments: [429, 503])
  func honorsHTTPDateRetryAfterAcrossPublicEndpoints(_ status: Int) async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let client = CodexResetsHTTPClient(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        if request.url == CodexResetsAPI.statusURL {
          return (
            Data(),
            publicResponse(
              request, status: status,
              headers: [
                "Retry-After": "Mon, 07 Sep 2026 08:10:00 GMT"
              ])
          )
        }
        return (publicPage(), publicResponse(request))
      }, now: { clock.now() })

    await #expect(throws: CodexResetsError.http(status)) {
      try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    }
    clock.advance(599)
    await #expect(throws: CodexResetsError.coolingDown) {
      try await client.load(CodexResetsAPI.historyURL, as: CodexResetsPage.self, revalidate: true)
    }
    #expect(await recorder.requests.count == 1)
    clock.advance(1)
    _ = try await client.load(CodexResetsAPI.historyURL, as: CodexResetsPage.self)
    #expect(await recorder.requests.count == 2)
  }

  @Test(arguments: ["invalid", "-1", "NaN", "Mon, 07 Sep 2026 07:00:00 GMT"])
  func invalidOrPastRetryAfterKeepsTheLocalBackoff(_ retryAfter: String) async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let client = CodexResetsHTTPClient(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        if await recorder.requests.count == 1 {
          return (
            Data(), publicResponse(request, status: 503, headers: ["Retry-After": retryAfter])
          )
        }
        return (publicStatus(), publicResponse(request))
      }, now: { clock.now() })
    await #expect(throws: CodexResetsError.http(503)) {
      try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    }
    clock.advance(29)
    await #expect(throws: CodexResetsError.coolingDown) {
      try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    }
    clock.advance(1)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 2)
  }

  @Test
  func noStore304DiscardsItsValidatorAndPersistentBody() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("public.json")
    let recorder = PublicAPIRequests()
    let client = CodexResetsHTTPClient(
      loader: HTTPDataLoader { request in
        await recorder.record(request)
        if await recorder.requests.count == 1 {
          return (
            publicStatus(),
            publicResponse(request, headers: ["Cache-Control": "max-age=0", "ETag": "initial"])
          )
        }
        if await recorder.requests.count == 2 {
          return (
            Data(), publicResponse(request, status: 304, headers: ["Cache-Control": "no-store"])
          )
        }
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        return (publicStatus(), publicResponse(request, headers: ["Cache-Control": "no-store"]))
      }, now: { publicAPINow }, cacheURL: cache)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    _ = try await client.load(CodexResetsAPI.statusURL, as: CodexResetsStatus.self)
    #expect(await recorder.requests.count == 3)

    let restarted = CodexResetsHTTPClient(
      loader: HTTPDataLoader { _ in
        throw URLError(.notConnectedToInternet)
      }, now: { publicAPINow }, cacheURL: cache)
    await #expect(throws: URLError.self) {
      try await restarted.load(
        CodexResetsAPI.statusURL, as: CodexResetsStatus.self, allowStale: true)
    }
  }
}
