import Foundation

enum ResetHistoryServiceError: LocalizedError, Equatable {
  case invalidResponse
  case invalidRequest
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "The reset history service returned an invalid response."
    case .invalidRequest: "The reset history request is invalid."
    case .unavailable: "The reset history service is unavailable."
    }
  }
}

struct ResetHistoryService: Sendable {
  let historyURL: URL
  private let client: CodexResetsHTTPClient
  private let now: @Sendable () -> Date

  init(historyURL: URL = CodexResetsAPI.historyURL) {
    self.historyURL = historyURL
    client = .live
    now = { Date() }
  }

  init(
    historyURL: URL = CodexResetsAPI.historyURL,
    loader: HTTPDataLoader,
    now: @escaping @Sendable () -> Date = { Date() },
    cacheURL: URL? = nil
  ) {
    self.historyURL = historyURL
    self.now = now
    client = CodexResetsHTTPClient(loader: loader, now: now, cacheURL: cacheURL)
  }

  func fetch(timeZoneIdentifier: String, range: ResetHistoryRange) async throws -> ResetHistory {
    guard let zone = TimeZone(identifier: timeZoneIdentifier),
      var components = URLComponents(url: historyURL, resolvingAgainstBaseURL: false)
    else { throw ResetHistoryServiceError.invalidRequest }
    var cursor: String?
    var cursors: Set<String> = []
    var records: [String: CodexResetsRecord] = [:]
    do {
      // Fetch the complete announced history, not the old server's aggregate
      // endpoint. Ranges, Monday-based weeks, local months and days are local.
      for _ in 0..<100 {
        try Task.checkCancellation()
        components.queryItems = [
          URLQueryItem(name: "limit", value: "100"),
          URLQueryItem(name: "order", value: "desc"),
        ]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let url = components.url else { throw ResetHistoryServiceError.invalidRequest }
        let page = try await client.load(url, as: CodexResetsPage.self).value
        for record in page.data {
          if let previous = records[record.id], previous != record {
            throw CodexResetsError.incompleteHistory
          }
          records[record.id] = record
        }
        if !page.pagination.has_more {
          return try ResetHistory(
            codexResets: Array(records.values), now: now(), timeZone: zone, range: range
          )
        }
        guard let next = page.pagination.next_cursor, cursors.insert(next).inserted else {
          throw CodexResetsError.incompleteHistory
        }
        cursor = next
      }
      throw CodexResetsError.incompleteHistory
    } catch let error as CodexResetsError {
      switch error {
      case .http(400): throw ResetHistoryServiceError.invalidRequest
      case .http(429), .http(503), .coolingDown: throw ResetHistoryServiceError.unavailable
      default: throw ResetHistoryServiceError.invalidResponse
      }
    }
  }
}
