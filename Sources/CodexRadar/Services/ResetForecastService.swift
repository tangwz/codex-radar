import Foundation

enum ResetForecastServiceError: LocalizedError, Equatable {
  case invalidResponse
  case notInitialized

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "The reset service returned an invalid response."
    case .notInitialized:
      "Reset status is not available yet."
    }
  }
}

struct HTTPDataLoader: Sendable {
  let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let live = HTTPDataLoader { request in
    try await URLSession.shared.data(for: request)
  }
}

enum ResetForecastFetchResult: Equatable, Sendable {
  case updated(ResetForecast, etag: String?)
  case notModified
}

struct ResetForecastService: Sendable {
  let currentURL: URL
  let loader: HTTPDataLoader

  init(
    currentURL: URL = URL(string: "https://codexradar.com/v1/current")!,
    loader: HTTPDataLoader = .live
  ) {
    self.currentURL = currentURL
    self.loader = loader
  }

  func fetch(etag: String?) async throws -> ResetForecastFetchResult {
    var request = URLRequest(url: currentURL)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let etag {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }

    let (data, response) = try await loader.load(request)
    guard let http = response as? HTTPURLResponse else {
      throw ResetForecastServiceError.invalidResponse
    }

    if http.statusCode == 304 {
      return .notModified
    }
    if http.statusCode == 503,
      let error = try? JSONDecoder().decode(CurrentErrorEnvelope.self, from: data),
      error.error.code == "not_initialized"
    {
      throw ResetForecastServiceError.notInitialized
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ResetForecastServiceError.invalidResponse
    }

    return .updated(
      try ResetForecast.decoder.decode(ResetForecast.self, from: data),
      etag: http.value(forHTTPHeaderField: "ETag")
    )
  }

}

private struct CurrentErrorEnvelope: Decodable {
  struct APIError: Decodable {
    let code: String
  }

  let error: APIError
}
