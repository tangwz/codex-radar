import Foundation

/// A client-side HTTP cache, not a proxy/backend. Only validated public API
/// responses are stored. No Codex account token, session content or cookie is sent.
actor CodexResetsHTTPClient {
  struct Snapshot<Value: Sendable>: Sendable {
    let value: Value
    let stale: Bool
    let etag: String?
  }
  private struct Entry: Codable {
    let data: Data
    var etag: String?
    var expiresAt: Date
    var checkedAt: Date
    var lifetime: TimeInterval
  }

  static let live = CodexResetsHTTPClient(
    loader: .live,
    cacheURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("CodexRadar/codex-resets-http-v1.json")
  )

  private let loader: HTTPDataLoader
  private let now: @Sendable () -> Date
  private let cacheURL: URL?
  private var entries: [String: Entry] = [:]
  private var didLoadDisk = false
  private var retryAt: [String: Date] = [:]
  private var failures: [String: Int] = [:]
  private var hostRetryAt: Date = .distantPast

  init(
    loader: HTTPDataLoader,
    now: @escaping @Sendable () -> Date = { Date() },
    cacheURL: URL? = nil
  ) {
    self.loader = loader
    self.now = now
    self.cacheURL = cacheURL
  }

  func load<Value: CodexResetsDocument>(
    _ url: URL, as type: Value.Type, allowStale: Bool = false, revalidate: Bool = false
  ) async throws -> Snapshot<Value> {
    try Task.checkCancellation()
    loadDiskIfNeeded()
    let key = url.absoluteString
    let instant = now()
    var previous = entries[key]
    let cached: Value?
    if let previous, let decoded = try? decode(type, data: previous.data) {
      cached = decoded
    } else {
      cached = nil
      entries.removeValue(forKey: key)
      previous = nil
    }
    if !revalidate, let previous, let cached,
      previous.checkedAt <= instant, previous.expiresAt > instant,
      retryAt[key] == nil
    {
      return Snapshot(value: cached, stale: false, etag: previous.etag)
    }
    if max(retryAt[key] ?? .distantPast, hostRetryAt) > instant {
      if allowStale, let previous, let cached {
        return Snapshot(value: cached, stale: true, etag: previous.etag)
      }
      throw CodexResetsError.coolingDown
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("CodexRadar", forHTTPHeaderField: "User-Agent")
    // Never send a caller-supplied validator without its corresponding body.
    if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    do {
      let (data, response) = try await loader.load(request)
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse else {
        throw CodexResetsError.invalidResponse
      }
      let receivedAt = now()
      if http.statusCode == 429 || http.statusCode == 503 {
        if let header = http.value(forHTTPHeaderField: "Retry-After"),
          let retryDate = Self.retryDate(header, receivedAt: receivedAt)
        {
          hostRetryAt = max(hostRetryAt, retryDate)
        }
      }
      let age = Self.age(http, requestedAt: instant, receivedAt: receivedAt)
      let value: Value
      var entry: Entry
      if http.statusCode == 304 {
        guard var retained = previous, let cached, retained.etag != nil else {
          throw CodexResetsError.invalidResponse
        }
        retained.etag = http.value(forHTTPHeaderField: "ETag") ?? retained.etag
        retained.lifetime = Self.lifetime(http, fallback: retained.lifetime)
        retained.expiresAt = receivedAt.addingTimeInterval(max(0, retained.lifetime - age))
        retained.checkedAt = receivedAt
        value = cached
        entry = retained
      } else {
        guard http.statusCode == 200 else { throw CodexResetsError.http(http.statusCode) }
        guard data.count <= 2_000_000 else { throw CodexResetsError.invalidResponse }
        value = try decode(type, data: data)
        let lifetime = Self.lifetime(http, fallback: 60)
        entry = Entry(
          data: data, etag: http.value(forHTTPHeaderField: "ETag"),
          expiresAt: receivedAt.addingTimeInterval(max(0, lifetime - age)), checkedAt: receivedAt,
          lifetime: lifetime
        )
      }
      failures.removeValue(forKey: key)
      retryAt.removeValue(forKey: key)
      if Self.directives(http).contains("no-store") {
        entries.removeValue(forKey: key)
      } else {
        entries[key] = entry
      }
      persist()
      return Snapshot(value: value, stale: false, etag: entry.etag)
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      let count = min((failures[key] ?? 0) + 1, 8)
      failures[key] = count
      retryAt[key] = now().addingTimeInterval(min(900, 30 * pow(2, Double(count - 1))))
      if allowStale, let previous, let cached {
        return Snapshot(value: cached, stale: true, etag: previous.etag)
      }
      throw error
    }
  }

  private func decode<Value: CodexResetsDocument>(_ type: Value.Type, data: Data) throws -> Value {
    let value = try APIJSONCoding.makeDecoder().decode(type, from: data)
    try value.validate()
    return value
  }

  private static func directives(_ response: HTTPURLResponse) -> [String] {
    (response.value(forHTTPHeaderField: "Cache-Control") ?? "")
      .lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func lifetime(_ response: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval
  {
    let parts = directives(response)
    if parts.contains("no-cache") || parts.contains("no-store") { return 0 }
    // This is a private client cache: do not substitute s-maxage for max-age.
    let maxAge = parts.first(where: { $0.hasPrefix("max-age=") })
      .flatMap { TimeInterval($0.dropFirst(8).replacingOccurrences(of: "\"", with: "")) }
    let duration = maxAge ?? fallback
    return duration.isFinite ? max(0, duration) : 0
  }

  private static func age(
    _ response: HTTPURLResponse, requestedAt: Date, receivedAt: Date
  ) -> TimeInterval {
    let date = response.value(forHTTPHeaderField: "Date").flatMap(httpDate)
    let apparentAge = max(0, receivedAt.timeIntervalSince(date ?? receivedAt))
    let ageValue = TimeInterval(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0
    guard ageValue.isFinite else { return .infinity }
    let responseDelay = max(0, receivedAt.timeIntervalSince(requestedAt))
    return max(apparentAge, max(0, ageValue) + responseDelay)
  }

  private static func retryDate(_ header: String, receivedAt: Date) -> Date? {
    let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let seconds = TimeInterval(value), seconds.isFinite
    {
      return receivedAt.addingTimeInterval(seconds)
    }
    return httpDate(value)
  }

  private static func httpDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    formatter.isLenient = false
    return formatter.date(from: value)
  }

  private func loadDiskIfNeeded() {
    guard !didLoadDisk else { return }
    didLoadDisk = true
    guard let cacheURL,
      let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 12_000_000,
      let bytes = try? Data(contentsOf: cacheURL),
      let saved = try? JSONDecoder().decode([String: Entry].self, from: bytes),
      saved.count <= 64
    else { return }
    entries = saved.filter { $0.value.data.count <= 2_000_000 }
  }

  private func persist() {
    if entries.count > 64 {
      let keep = entries.sorted { $0.value.checkedAt > $1.value.checkedAt }.prefix(64)
      entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
    guard let cacheURL, let bytes = try? JSONEncoder().encode(entries), bytes.count <= 12_000_000
    else { return }
    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try bytes.write(to: cacheURL, options: .atomic)
    } catch {
      // Disk caching is best-effort; an unwritable cache must not break live data.
    }
  }
}
