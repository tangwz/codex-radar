import Foundation

struct CodexSessionScanner: Sendable {
  func scan(codexHome: URL = Self.defaultCodexHome()) throws -> [TokenUsageEvent] {
    let roots = [
      codexHome.appending(path: "sessions", directoryHint: .isDirectory),
      codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory),
    ]
    let parser = CodexSessionParser()

    // Match CodexBar's stable row scope: session_id first, payload.id only as its fallback.
    var seenUsageBySessionID: [String: Set<UsageIdentity>] = [:]
    var sessionEvents: [TokenUsageEvent] = []
    var legacyEvents: [TokenUsageEvent] = []

    for root in roots {
      for fileURL in try sessionFiles(under: root) {
        var events: [TokenUsageEvent] = []
        var state = CodexSessionParser.State()
        do {
          try JSONLLineReader().forEachLine(at: fileURL) { line in
            let event = autoreleasepool {
              parser.parse(line: line, state: &state)
            }
            if let event {
              events.append(event)
            }
          }
        } catch {
          continue
        }

        guard let sessionID = state.sessionID else {
          legacyEvents.append(contentsOf: events)
          continue
        }

        for event in events {
          let identity = UsageIdentity(event: event)
          if seenUsageBySessionID[sessionID, default: []].insert(identity).inserted {
            sessionEvents.append(event)
          }
        }
      }
    }

    return (legacyEvents + sessionEvents)
      .sorted { $0.timestamp < $1.timestamp }
  }

  static func defaultCodexHome() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
      return URL(filePath: override, directoryHint: .isDirectory)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex", directoryHint: .isDirectory)
  }

  private func sessionFiles(under root: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return enumerator.compactMap { item in
      guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
      return url
    }
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
    self.eventIndex = event.eventIndex ?? 0
    self.day = Calendar.current.startOfDay(for: event.timestamp)
    self.inputTokens = event.inputTokens
    self.cachedInputTokens = event.cachedInputTokens
    self.outputTokens = event.outputTokens
    self.turnID = event.turnID
    self.model = event.model
  }
}
