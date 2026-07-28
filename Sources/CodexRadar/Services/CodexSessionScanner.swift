import Foundation

struct CodexSessionFileFingerprint: Codable, Equatable, Sendable {
  let path: String
  let resourceIdentifier: String?
  let size: Int64
  let modificationDate: Date

  var cacheIdentity: String {
    resourceIdentifier.map { "resource:\($0)" } ?? "path:\(path)"
  }

  func hasSameContent(as other: Self) -> Bool {
    guard size == other.size, modificationDate == other.modificationDate else {
      return false
    }
    if let resourceIdentifier, let otherIdentifier = other.resourceIdentifier {
      return resourceIdentifier == otherIdentifier
    }
    return path == other.path
  }
}

struct CodexSessionFileDescriptor: Equatable, Sendable {
  let url: URL
  let fingerprint: CodexSessionFileFingerprint
}

struct ParsedCodexSessionFile: Equatable, Sendable {
  let sessionID: String?
  let events: [TokenUsageEvent]
}

struct CodexSessionFileRecord: Codable, Equatable, Sendable {
  let fingerprint: CodexSessionFileFingerprint
  let sessionID: String?
  let events: [TokenUsageEvent]
}

struct TokenUsageManifest: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let parserVersion: Int
  let files: [CodexSessionFileRecord]

  init(files: [CodexSessionFileRecord]) {
    schemaVersion = TokenUsageCacheVersion.schema
    parserVersion = TokenUsageCacheVersion.parser
    self.files = files
  }

  var isCompatible: Bool {
    schemaVersion == TokenUsageCacheVersion.schema
      && parserVersion == TokenUsageCacheVersion.parser
  }
}

struct CodexSessionScanner: Sendable {
  func scan(codexHome: URL = Self.defaultCodexHome()) throws -> [TokenUsageEvent] {
    let records = try discoverFiles(codexHome: codexHome).compactMap {
      descriptor -> CodexSessionFileRecord? in
      guard let parsed = try? parseFile(at: descriptor.url) else { return nil }
      return CodexSessionFileRecord(
        fingerprint: descriptor.fingerprint,
        sessionID: parsed.sessionID,
        events: parsed.events
      )
    }
    return Self.deduplicatedEvents(from: records)
  }

  func discoverFiles(
    codexHome: URL = Self.defaultCodexHome()
  ) throws -> [CodexSessionFileDescriptor] {
    let roots = [
      codexHome.appending(path: "sessions", directoryHint: .isDirectory),
      codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory),
    ]
    return try roots.flatMap(sessionFiles).sorted {
      $0.fingerprint.path < $1.fingerprint.path
    }
  }

  func fingerprint(for fileURL: URL) throws -> CodexSessionFileFingerprint {
    let values = try fileURL.resourceValues(
      forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileResourceIdentifierKey,
      ]
    )
    guard values.isRegularFile == true else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    return CodexSessionFileFingerprint(
      path: fileURL.standardizedFileURL.path,
      resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
      size: Int64(values.fileSize ?? 0),
      modificationDate: values.contentModificationDate ?? .distantPast
    )
  }

  func parseFile(at fileURL: URL) throws -> ParsedCodexSessionFile {
    let parser = CodexSessionParser()
    var state = CodexSessionParser.State()
    var events: [TokenUsageEvent] = []
    try JSONLLineReader().forEachLine(at: fileURL) { line in
      let event = autoreleasepool {
        parser.parse(line: line, state: &state)
      }
      if let event {
        events.append(event)
      }
    }
    return ParsedCodexSessionFile(sessionID: state.sessionID, events: events)
  }

  static func deduplicatedEvents(
    from records: [CodexSessionFileRecord]
  ) -> [TokenUsageEvent] {
    var seenUsageBySessionID: [String: Set<UsageIdentity>] = [:]
    var sessionEvents: [TokenUsageEvent] = []
    var legacyEvents: [TokenUsageEvent] = []

    for record in records {
      guard let sessionID = record.sessionID else {
        legacyEvents.append(contentsOf: record.events)
        continue
      }
      for event in record.events {
        let identity = UsageIdentity(event: event)
        if seenUsageBySessionID[sessionID, default: []].insert(identity).inserted {
          sessionEvents.append(event)
        }
      }
    }
    return (legacyEvents + sessionEvents).sorted { $0.timestamp < $1.timestamp }
  }

  static func defaultCodexHome() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
      return URL(filePath: override, directoryHint: .isDirectory)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex", directoryHint: .isDirectory)
  }

  private func sessionFiles(
    under root: URL
  ) throws -> [CodexSessionFileDescriptor] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    var enumerationError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .fileSizeKey,
          .contentModificationDateKey,
          .fileResourceIdentifierKey,
        ],
        options: [.skipsHiddenFiles],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else {
      throw CocoaError(.fileReadUnknown)
    }

    var descriptors: [CodexSessionFileDescriptor] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      descriptors.append(
        CodexSessionFileDescriptor(url: url, fingerprint: try fingerprint(for: url))
      )
    }
    if let enumerationError {
      throw enumerationError
    }
    return descriptors
  }
}

private struct UsageIdentity: Hashable {
  let eventIndex: Int
  let day: Date
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let turnID: String?
  let model: String?

  init(event: TokenUsageEvent) {
    eventIndex = event.eventIndex ?? 0
    day = Calendar.current.startOfDay(for: event.timestamp)
    inputTokens = event.inputTokens
    cachedInputTokens = event.cachedInputTokens
    outputTokens = event.outputTokens
    turnID = event.turnID
    model = event.model
  }
}
