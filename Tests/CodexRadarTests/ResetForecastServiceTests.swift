import Foundation
import Testing
@testable import CodexRadar

struct ResetForecastServiceTests {
  @Test
  func usesPublicEndpointWithoutCredentialsOrUnmatchedValidator() async throws {
    let recorder = PublicAPIRequests()
    let service = ResetForecastService(loader: HTTPDataLoader { request in
      await recorder.record(request)
      return (publicStatus(), publicResponse(request))
    }, now: { publicAPINow })
    _ = try await service.fetch(etag: "old-backend-validator")
    let request = try #require(await recorder.requests.first)
    #expect(service.currentURL == CodexResetsAPI.statusURL)
    #expect(request.timeoutInterval == 15)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(!request.httpShouldHandleCookies)
  }

  @Test
  func revalidatesOnlyItsCachedBodyAndReprojectsExpiredWatchAfter304() async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let service = ResetForecastService(loader: HTTPDataLoader { request in
      await recorder.record(request)
      if await recorder.requests.count == 1 {
        return (publicStatus(watch: publicWatch()), publicResponse(request, headers: ["ETag": "watch-1", "Cache-Control": "max-age=0"]))
      }
      #expect(request.value(forHTTPHeaderField: "If-None-Match") == "watch-1")
      return (Data(), publicResponse(request, status: 304, headers: ["Cache-Control": "max-age=0"]))
    }, now: { clock.now() })
    guard case .updated(let first, _) = try await service.fetch(etag: nil) else { Issue.record("Expected status"); return }
    #expect(first.status == .candidate)
    clock.advance(3601)
    guard case .updated(let next, _) = try await service.fetch(etag: "watch-1") else { Issue.record("Expected reprojected status"); return }
    #expect(next.status == .monitoring)
    #expect(next.signalID == nil)
  }

  @Test
  func honorsClientMaxAgeAndAgeAndStillExpiresForecastLocally() async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let service = ResetForecastService(loader: HTTPDataLoader { request in
      await recorder.record(request)
      return (publicStatus(watch: publicWatch()), publicResponse(request, headers: ["Cache-Control": "max-age=14400, s-maxage=60", "Age": "50"]))
    }, now: { clock.now() })
    _ = try await service.fetch(etag: nil)
    clock.advance(3601)
    guard case .updated(let value, _) = try await service.fetch(etag: nil) else { Issue.record("Expected status"); return }
    #expect(value.status == .monitoring)
    #expect(await recorder.requests.count == 1)
    clock.advance(11000)
    _ = try await service.fetch(etag: nil)
    #expect(await recorder.requests.count == 2)
  }

  @Test
  func keepsLastGoodStatusAsStaleAndHonorsRetryAfter() async throws {
    let recorder = PublicAPIRequests()
    let clock = PublicAPIClock()
    let service = ResetForecastService(loader: HTTPDataLoader { request in
      await recorder.record(request)
      if await recorder.requests.count == 1 {
        return (publicStatus(record: publicRecord()), publicResponse(request, headers: ["Cache-Control": "max-age=0"]))
      }
      return (Data(), publicResponse(request, status: 429, headers: ["Retry-After": "600"]))
    }, now: { clock.now() })
    _ = try await service.fetch(etag: nil)
    guard case .updated(let retained, _) = try await service.fetch(etag: nil) else { Issue.record("Expected cached status"); return }
    #expect(retained.stale)
    #expect(!ResetForecastPresentation(forecast: retained).hasResetAlert)
    #expect(retained.lastResetAt != nil)
    clock.advance(60)
    _ = try await service.fetch(etag: nil)
    #expect(await recorder.requests.count == 2)
  }

  @Test
  func rejects304WithoutCachedBody() async {
    let service = ResetForecastService(loader: HTTPDataLoader { request in
      (Data(), publicResponse(request, status: 304))
    })
    await #expect(throws: ResetForecastServiceError.invalidResponse) { try await service.fetch(etag: "foreign") }
  }

  @Test
  func rejectsUnknownVersionsAndMalformedJSON() async {
    let unknown = ResetForecastService(loader: HTTPDataLoader { request in
      (publicStatus(version: "v2"), publicResponse(request))
    })
    await #expect(throws: ResetForecastServiceError.invalidResponse) { try await unknown.fetch(etag: nil) }
    let broken = ResetForecastService(loader: HTTPDataLoader { request in
      (Data("broken".utf8), publicResponse(request))
    })
    await #expect(throws: DecodingError.self) { try await broken.fetch(etag: nil) }
  }

  @Test
  func persistentCacheSurvivesRestartButDoesNotPretendOfflineDataIsFresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("public.json")
    let first = ResetForecastService(loader: HTTPDataLoader { request in
      (publicStatus(record: publicRecord()), publicResponse(request, headers: ["Cache-Control": "max-age=0"]))
    }, now: { publicAPINow }, cacheURL: cache)
    _ = try await first.fetch(etag: nil)
    let offline = ResetForecastService(loader: HTTPDataLoader { _ in throw URLError(.notConnectedToInternet) }, now: { publicAPINow }, cacheURL: cache)
    guard case .updated(let value, _) = try await offline.fetch(etag: nil) else { Issue.record("Expected cache"); return }
    #expect(value.stale)
    #expect(value.lastResetAt != nil)
  }
}
