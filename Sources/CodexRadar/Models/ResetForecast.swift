import Foundation

enum ResetStatus: String, Codable, Sendable {
  case monitoring
  case candidate
  case announced
  case completed
}

enum RecommendedAction: String, Codable, Sendable {
  case none
  case watch
  case wait
  case useNow = "use_now"
  case unknown
}

struct ResetTiming: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case exact
    case estimated
    case imminent
  }

  let kind: Kind
  let at: Date?
  let from: Date?
  let to: Date?

  init(kind: Kind, at: Date? = nil, from: Date? = nil, to: Date? = nil) {
    self.kind = kind
    self.at = at
    self.from = from
    self.to = to
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(Kind.self, forKey: .kind)
    at = try container.decodeIfPresent(Date.self, forKey: .at)
    from = try container.decodeIfPresent(Date.self, forKey: .from)
    to = try container.decodeIfPresent(Date.self, forKey: .to)

    let isValid =
      switch kind {
      case .exact:
        at != nil && from == nil && to == nil
      case .estimated:
        at == nil && from != nil && to != nil && from! <= to!
      case .imminent:
        at == nil && from == nil && to == nil
      }

    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Reset timing fields do not match its kind."
      )
    }
  }
}

struct ResetPostContext: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case reply
    case quote
  }

  let kind: Kind
  let text: String
  let authorHandle: String
  let url: URL

  enum CodingKeys: String, CodingKey {
    case kind
    case text
    case authorHandle = "author_handle"
    case url
  }
}

struct ResetSourcePost: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let createdAt: Date
  let url: URL
  let context: ResetPostContext?

  enum CodingKeys: String, CodingKey {
    case id
    case text
    case createdAt = "created_at"
    case url
    case context
  }
}

enum LastResetAvailability: Equatable, Sendable {
  case unavailable
  case none
  case resetAt(Date)
}

struct ResetForecast: Decodable, Equatable, Sendable {
  let schemaVersion: String
  let monitoredAt: Date
  let stale: Bool
  let status: ResetStatus
  let recommendedAction: RecommendedAction
  let message: String
  let signalID: String?
  let timing: ResetTiming?
  let sourceURL: URL?
  let posts: [ResetSourcePost]
  let lastReset: LastResetAvailability

  static var decoder: JSONDecoder {
    APIJSONCoding.makeDecoder()
  }

  static let placeholder = ResetForecast(
    schemaVersion: "1.0",
    monitoredAt: .distantPast,
    stale: true,
    status: .monitoring,
    recommendedAction: .unknown,
    message: "Monitoring has not initialized.",
    signalID: nil,
    timing: nil,
    sourceURL: nil,
    posts: [],
    lastReset: .unavailable
  )

  init(
    schemaVersion: String,
    monitoredAt: Date,
    stale: Bool,
    status: ResetStatus,
    recommendedAction: RecommendedAction,
    message: String,
    signalID: String?,
    timing: ResetTiming?,
    sourceURL: URL?,
    posts: [ResetSourcePost],
    lastReset: LastResetAvailability = .unavailable
  ) {
    self.schemaVersion = schemaVersion
    self.monitoredAt = monitoredAt
    self.stale = stale
    self.status = status
    self.recommendedAction = recommendedAction
    self.message = message
    self.signalID = signalID
    self.timing = timing
    self.sourceURL = sourceURL
    self.posts = posts
    self.lastReset = lastReset
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
    monitoredAt = try container.decode(Date.self, forKey: .monitoredAt)
    stale = try container.decode(Bool.self, forKey: .stale)
    status = try container.decode(ResetStatus.self, forKey: .status)
    recommendedAction = try container.decode(RecommendedAction.self, forKey: .recommendedAction)
    message = try container.decode(String.self, forKey: .message)
    signalID = try container.decodeIfPresent(String.self, forKey: .signalID)
    timing = try container.decodeIfPresent(ResetTiming.self, forKey: .timing)
    sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
    posts = try container.decode([ResetSourcePost].self, forKey: .posts)
    if container.contains(.lastResetAt) {
      if let value = try container.decodeIfPresent(Date.self, forKey: .lastResetAt) {
        lastReset = .resetAt(value)
      } else {
        lastReset = .none
      }
    } else {
      lastReset = .unavailable
    }

    guard posts.count <= 5 else {
      throw DecodingError.dataCorruptedError(
        forKey: .posts,
        in: container,
        debugDescription: "Public reset evidence must contain at most five posts."
      )
    }
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case monitoredAt = "monitored_at"
    case stale
    case status
    case recommendedAction = "recommended_action"
    case message
    case signalID = "signal_id"
    case timing
    case sourceURL = "source_url"
    case posts
    case lastResetAt = "last_reset_at"
  }

  var lastResetAt: Date? {
    guard case .resetAt(let value) = lastReset else { return nil }
    return value
  }
}
