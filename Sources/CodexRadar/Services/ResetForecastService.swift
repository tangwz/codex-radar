import Foundation

enum ResetForecastServiceError: LocalizedError, Equatable {
  case invalidResponse
  case notInitialized

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "The reset service returned an invalid response."
    case .notInitialized: "Reset status is not available yet."
    }
  }
}

struct HTTPDataLoader: Sendable {
  let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let live: HTTPDataLoader = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    return HTTPDataLoader { request in try await session.data(for: request) }
  }()
}

enum ResetForecastFetchResult: Equatable, Sendable {
  case updated(ResetForecast, etag: String?)
  case notModified
}

struct ResetForecastService: Sendable {
  let currentURL: URL
  private let client: CodexResetsHTTPClient
  private let now: @Sendable () -> Date

  init(currentURL: URL = CodexResetsAPI.statusURL) {
    self.currentURL = currentURL
    client = .live
    now = { Date() }
  }

  init(
    currentURL: URL = CodexResetsAPI.statusURL,
    loader: HTTPDataLoader,
    now: @escaping @Sendable () -> Date = { Date() },
    cacheURL: URL? = nil
  ) {
    self.currentURL = currentURL
    self.now = now
    client = CodexResetsHTTPClient(loader: loader, now: now, cacheURL: cacheURL)
  }

  func fetch(etag: String?) async throws -> ResetForecastFetchResult {
    do {
      // The HTTP client owns each ETag together with its body. The old store's
      // validator alone is deliberately not trusted, including across restarts.
      let snapshot = try await client.load(currentURL, as: CodexResetsStatus.self, allowStale: true)
      return .updated(
        snapshot.value.forecast(now: now(), stale: snapshot.stale), etag: snapshot.etag
      )
    } catch is CodexResetsError {
      throw ResetForecastServiceError.invalidResponse
    }
  }
}
