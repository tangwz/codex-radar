import Foundation

/// Wire types for the published /api/openapi.json contract. These are not
/// the legacy backend's domain snapshots and never contain account credentials.
enum CodexResetsAPI {
  static let schema = "codex-resets-v1"
  static let statusURL = URL(string: "https://codex-resets.com/api/v1/status")!
  static let historyURL = URL(string: "https://codex-resets.com/api/v1/resets")!
}

protocol CodexResetsDocument: Decodable, Sendable {
  func validate() throws
}

enum CodexResetsError: Error, Equatable {
  case invalidResponse
  case http(Int)
  case coolingDown
  case incompleteHistory
}

struct CodexResetsMeta: Decodable, Sendable {
  let api_version: String
  let generated_at: Date

  func validate() throws {
    guard api_version == "v1" else { throw CodexResetsError.invalidResponse }
  }
}

struct CodexResetsSource: Decodable, Equatable, Sendable {
  let type: String
  let author: String?
  let url: URL?

  func validate() throws {
    guard type == "x_post" || type == "observed" else {
      throw CodexResetsError.invalidResponse
    }
    if type == "x_post", url == nil || author == nil {
      throw CodexResetsError.invalidResponse
    }
    if let url {
      let hosts: Set<String> = [
        "x.com", "www.x.com", "twitter.com", "www.twitter.com", "codex-resets.com"
      ]
      guard url.scheme?.lowercased() == "https",
        let host = url.host?.lowercased(), hosts.contains(host),
        url.user == nil, url.password == nil, url.port == nil || url.port == 443
      else { throw CodexResetsError.invalidResponse }
    }
  }
}

struct CodexResetsRecord: Decodable, Equatable, Sendable {
  enum Kind: String, Decodable, Sendable { case regular, banked }
  let id: String
  let reset_type: Kind
  let announced_at: Date
  let text: String
  let source: CodexResetsSource

  func validate() throws {
    guard !id.isEmpty, id.count <= 64 else { throw CodexResetsError.invalidResponse }
    try source.validate()
  }
}

struct CodexResetsWatch: Decodable, Sendable {
  let level: String
  let reset_chance_percent: Int?
  let forecast_window: String
  let observed_at: Date
  let expires_at: Date
  let text: String
  let source: CodexResetsSource

  func validate() throws {
    guard ["elevated", "strong"].contains(level), observed_at < expires_at,
      reset_chance_percent.map({ (0...100).contains($0) }) ?? true
    else { throw CodexResetsError.invalidResponse }
    try source.validate()
  }

  /// A forecast's wording, probability and expiration can change without
  /// becoming a new event. A source URL is not fabricated from a tweet ID.
  var signalID: String {
    "codex-resets:watch:" + (source.url?.absoluteString ?? observed_at.ISO8601Format())
  }
}

struct CodexResetsStatus: CodexResetsDocument {
  struct Payload: Decodable, Sendable {
    let latest_reset: CodexResetsRecord?
    let active_watch: CodexResetsWatch?
    let stats: Stats

    enum CodingKeys: String, CodingKey { case latest_reset, active_watch, stats }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      // Required nullable properties: a missing key is not "no announcement".
      latest_reset = try c.decode(CodexResetsRecord?.self, forKey: .latest_reset)
      active_watch = try c.decode(CodexResetsWatch?.self, forKey: .active_watch)
      stats = try c.decode(Stats.self, forKey: .stats)
    }
  }
  struct Stats: Decodable, Sendable {
    let total: Int
    let last_reset_at: Date?
  }
  let data: Payload
  let meta: CodexResetsMeta

  func validate() throws {
    try meta.validate()
    guard data.stats.total >= 0 else { throw CodexResetsError.invalidResponse }
    try data.latest_reset?.validate()
    try data.active_watch?.validate()
  }

  func forecast(now: Date, stale: Bool) -> ResetForecast {
    let latest = data.latest_reset.flatMap { $0.announced_at <= now ? $0 : nil }
    let lastReset: LastResetAvailability = latest.map { .resetAt($0.announced_at) }
      ?? data.stats.last_reset_at.flatMap { $0 <= now ? .resetAt($0) : nil } ?? .none
    var status: ResetStatus = .monitoring
    var action: RecommendedAction = .none
    var signalID: String?
    var message = latest?.text ?? "No announcement is available from Codex Resets."
    var source = latest?.source
    var evidenceDate = latest?.announced_at
    var evidenceID = latest?.id

    // This is a local display/notification window, not a claim about when an
    // account's quota was reset. Historical records must not light the badge forever.
    if let latest, now.timeIntervalSince(latest.announced_at) < 24 * 60 * 60 {
      status = .announced
      signalID = "codex-resets:reset:" + latest.id
    }
    if let watch = data.active_watch,
      watch.observed_at <= now, watch.expires_at > now,
      latest.map({ watch.observed_at > $0.announced_at }) ?? true
    {
      status = .candidate
      action = .watch
      signalID = watch.signalID
      message = watch.text + "\n" + watch.forecast_window
      source = watch.source
      evidenceDate = watch.observed_at
      evidenceID = watch.signalID
    }
    let posts: [ResetSourcePost]
    if let url = source?.url, let date = evidenceDate, let id = evidenceID {
      posts = [ResetSourcePost(id: id, text: message, createdAt: date, url: url, context: nil)]
    } else {
      posts = []
    }
    return ResetForecast(
      schemaVersion: CodexResetsAPI.schema,
      monitoredAt: meta.generated_at,
      stale: stale,
      status: status,
      recommendedAction: stale ? .unknown : action,
      message: message,
      signalID: signalID,
      timing: nil, // expires_at and free-text forecast_window are NOT reset deadlines.
      sourceURL: source?.url,
      posts: posts,
      lastReset: lastReset
    )
  }
}

struct CodexResetsPage: CodexResetsDocument {
  struct Pagination: Decodable, Sendable {
    let has_more: Bool
    let next_cursor: String?
  }
  let data: [CodexResetsRecord]
  let pagination: Pagination
  let meta: CodexResetsMeta

  func validate() throws {
    try meta.validate()
    guard data.count <= 100 else { throw CodexResetsError.invalidResponse }
    for record in data { try record.validate() }
    if pagination.has_more {
      guard !data.isEmpty, let cursor = pagination.next_cursor,
        !cursor.isEmpty, cursor.count <= 1024,
        cursor.unicodeScalars.allSatisfy({
          (48...57).contains($0.value) || (65...90).contains($0.value)
            || (97...122).contains($0.value) || $0 == "_" || $0 == "-"
        })
      else { throw CodexResetsError.incompleteHistory }
    }
  }
}
