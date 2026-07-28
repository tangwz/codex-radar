import Foundation
import Testing

@testable import CodexRadar

struct CodexSessionScannerTests {
  @Test
  func discoversAndParsesOneSessionFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "sessions/2026/07/28/session.jsonl")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let contents = """
      {"timestamp":"2026-07-28T00:00:00Z","type":"session_meta","payload":{"session_id":"session-1"}}
      {"timestamp":"2026-07-28T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      """
    try Data(contents.utf8).write(to: file)

    let scanner = CodexSessionScanner()
    let files = try scanner.discoverFiles(codexHome: root)
    let parsed = try scanner.parseFile(at: try #require(files.first).url)

    #expect(files.count == 1)
    #expect(parsed.sessionID == "session-1")
    #expect(parsed.events.map(\.totalTokens) == [110])
  }

  @Test
  func treatsAPathChangeWithTheSameResourceAsReusableContent() {
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let active = CodexSessionFileFingerprint(
      path: "/tmp/sessions/a.jsonl",
      resourceIdentifier: "resource-1",
      size: 100,
      modificationDate: modifiedAt
    )
    let archived = CodexSessionFileFingerprint(
      path: "/tmp/archived_sessions/a.jsonl",
      resourceIdentifier: "resource-1",
      size: 100,
      modificationDate: modifiedAt
    )

    #expect(active.hasSameContent(as: archived))
    #expect(active.cacheIdentity == archived.cacheIdentity)
  }

  @Test
  func skipsNonRegularJSONLEntriesWhileScanningValidFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let validFile = root.appending(path: "sessions/valid.jsonl")
    let nonRegularEntry = root.appending(path: "sessions/not-a-file.jsonl")
    try FileManager.default.createDirectory(
      at: validFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: nonRegularEntry, withIntermediateDirectories: true)
    let contents = """
      {"timestamp":"2026-07-28T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      """
    try Data(contents.utf8).write(to: validFile)

    let events = try CodexSessionScanner().scan(codexHome: root)

    #expect(events.map(\.totalTokens) == [110])
  }

  @Test
  func scansActiveAndArchivedJSONLSessions() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let active = root.appending(path: "sessions/2026/07/14/active.jsonl")
    let archived = root.appending(path: "archived_sessions/archived.jsonl")
    let ignored = root.appending(path: "sessions/ignored.txt")
    try FileManager.default.createDirectory(
      at: active.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: archived.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let line = """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      """
    try Data(line.utf8).write(to: active)
    try Data(line.utf8).write(to: archived)
    try Data(line.utf8).write(to: ignored)

    let events = try CodexSessionScanner().scan(codexHome: root)

    #expect(events.count == 2)
    #expect(events.reduce(0) { $0 + $1.totalTokens } == 220)
  }

  @Test
  func keepsMostCompleteFileForDuplicateSessionIdentifier() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let partial = root.appending(path: "sessions/2026/07/14/partial.jsonl")
    let complete = root.appending(path: "archived_sessions/complete.jsonl")
    try FileManager.default.createDirectory(
      at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: complete.deletingLastPathComponent(), withIntermediateDirectories: true)

    let metadata =
      """
      {"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"file-copy","session_id":"stable-session"}}
      """
    let first =
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10},"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      """
    let second =
      """
      {"timestamp":"2026-07-14T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"output_tokens":20},"last_token_usage":{"input_tokens":60,"output_tokens":10}}}}
      """
    try Data(([metadata, first].joined(separator: "\n")).utf8).write(to: partial)
    try Data(([metadata, first, second].joined(separator: "\n")).utf8).write(to: complete)

    let events = try CodexSessionScanner().scan(codexHome: root)

    #expect(events.count == 2)
    #expect(events.reduce(0) { $0 + $1.totalTokens } == 180)
  }

  @Test
  func preservesDistinctTurnsWhenDuplicateSessionsShareUsageValues() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = root.appending(path: "sessions/first.jsonl")
    let second = root.appending(path: "sessions/second.jsonl")
    try FileManager.default.createDirectory(
      at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
    let metadata =
      """
      {"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"session_id":"stable-session"}}
      """
    func event(turnID: String) -> String {
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","turn_id":"\(turnID)","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      """
    }
    try Data(([metadata, event(turnID: "turn-a")].joined(separator: "\n")).utf8)
      .write(to: first)
    try Data(([metadata, event(turnID: "turn-b")].joined(separator: "\n")).utf8)
      .write(to: second)

    let events = try CodexSessionScanner().scan(codexHome: root)

    #expect(events.count == 2)
    #expect(Set(events.compactMap(\.turnID)) == ["turn-a", "turn-b"])
  }

  @Test
  func usesStableSessionIdentifierAsDeduplicationScope() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = root.appending(path: "sessions/first.jsonl")
    let second = root.appending(path: "sessions/second.jsonl")
    try FileManager.default.createDirectory(
      at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
    let event =
      """
      {"timestamp":"2026-07-14T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
      """
    func metadata(rowID: String) -> String {
      """
      {"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"\(rowID)","session_id":"stable-session"}}
      """
    }
    try Data(([metadata(rowID: "row-a"), event].joined(separator: "\n")).utf8)
      .write(to: first)
    try Data(([metadata(rowID: "row-b"), event].joined(separator: "\n")).utf8)
      .write(to: second)

    let events = try CodexSessionScanner().scan(codexHome: root)

    #expect(events.count == 1)
    #expect(events[0].totalTokens == 110)
  }
}
