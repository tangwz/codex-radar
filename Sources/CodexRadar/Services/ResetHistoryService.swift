import Foundation

enum ResetHistoryServiceError: LocalizedError, Equatable {
  case invalidResponse
  case invalidRequest
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "The reset history service returned an invalid response."
    case .invalidRequest:
      "The reset history request is invalid."
    case .unavailable:
      "The reset history service is unavailable."
    }
  }
}

struct ResetHistoryService: Sendable {
  let historyURL: URL
  let loader: HTTPDataLoader

  init(
    historyURL: URL = URL(
      string: "https://codex-radar-monitor.terencetang.workers.dev/v1/history"
    )!,
    loader: HTTPDataLoader = .live
  ) {
    self.historyURL = historyURL
    self.loader = loader
  }

  func fetch(
    timeZoneIdentifier: String,
    range: ResetHistoryRange
  ) async throws -> ResetHistory {
    guard
      TimeZone(identifier: timeZoneIdentifier) != nil,
      var components = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)
    else {
      throw ResetHistoryServiceError.invalidRequest
    }

    components.queryItems = [
      URLQueryItem(name: "time_zone", value: timeZoneIdentifier)
    ]
    if let queryValue = range.queryValue {
      components.queryItems?.append(
        URLQueryItem(name: "range", value: queryValue)
      )
    }
    guard let url = components.url else {
      throw ResetHistoryServiceError.invalidRequest
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await loader.load(request)
    guard let http = response as? HTTPURLResponse else {
      throw ResetHistoryServiceError.invalidResponse
    }

    switch http.statusCode {
    case 200..<300:
      let history = try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: data)
      guard history.timeZone == timeZoneIdentifier, history.range == range else {
        throw ResetHistoryServiceError.invalidResponse
      }
      return history
    case 400:
      throw ResetHistoryServiceError.invalidRequest
    case 503:
      throw ResetHistoryServiceError.unavailable
    default:
      throw ResetHistoryServiceError.invalidResponse
    }
  }
}
