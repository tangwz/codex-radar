import Foundation

enum ResetForecastServiceError: LocalizedError {
  case invalidResponse

  var errorDescription: String? {
    "The reset feed returned an invalid response."
  }
}

struct ResetForecastService: Sendable {
  let feedURL: URL

  init(feedURL: URL = URL(string: "https://codexradar.com/feed.xml")!) {
    self.feedURL = feedURL
  }

  func fetch(now: Date = .now) async throws -> ResetForecast {
    var request = URLRequest(url: feedURL)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadRevalidatingCacheData
    let (data, response) = try await URLSession.shared.data(for: request)

    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw ResetForecastServiceError.invalidResponse
    }
    return try ResetForecastRSSParser().parse(data: data, now: now)
  }
}
