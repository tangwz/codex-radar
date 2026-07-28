import Foundation
import Testing

@testable import CodexRadar

struct TokenUsageRepositoryTests {
  @Test
  func unchangedRefreshParsesEachFileOnlyOnce() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)

    let first = await context.repository.refresh(timeZone: context.timeZone)
    let second = await context.repository.refresh(timeZone: context.timeZone)

    #expect(first.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(second.snapshot == first.snapshot)
    #expect(context.parseCount.value == 1)
  }

  @Test
  func changedFileIsReparsedAndReplacesItsOldContribution() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)
    _ = await context.repository.refresh(timeZone: context.timeZone)

    try context.writeSession(input: 250, output: 25, modifiedAt: 1_700_000_100)
    let refreshed = await context.repository.refresh(timeZone: context.timeZone)

    #expect(refreshed.snapshot?.metrics(for: .day).totalTokens == 275)
    #expect(context.parseCount.value == 2)
  }

  @Test
  func sourceFailureKeepsTheLastCachedSnapshot() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)
    let first = await context.repository.refresh(timeZone: context.timeZone)
    context.discoveryError.value = CocoaError(.fileReadNoPermission)

    let failed = await context.repository.refresh(timeZone: context.timeZone)

    #expect(failed.snapshot == first.snapshot)
    #expect(failed.issues == [.sourceUnavailable])
  }

  @Test
  func deletingTheOnlyFileProducesAnEmptySnapshot() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)
    _ = await context.repository.refresh(timeZone: context.timeZone)
    try FileManager.default.removeItem(at: context.file)

    let refreshed = await context.repository.refresh(timeZone: context.timeZone)

    #expect(refreshed.snapshot?.hasUsageData == false)
  }

  @Test
  func cachedSnapshotIsRejectedForAnotherTimeZone() async throws {
    let context = try RepositoryTestContext()
    defer { context.remove() }
    try context.writeSession(input: 100, output: 10)
    _ = await context.repository.refresh(timeZone: context.timeZone)

    let other = await context.repository.cachedSnapshot(
      timeZone: TimeZone(identifier: "Asia/Shanghai")!
    )

    #expect(other == nil)
  }

  @Test
  func movedFileWithStableResourceIdentifierReusesParsedEvents() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let active = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: modifiedAt
    )
    let archived = descriptor(
      path: "/tmp/archived_sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: modifiedAt
    )
    let current = LockedBox(active)
    let parseCount = LockedBox(0)
    let parsed = ParsedCodexSessionFile(
      sessionID: "session-1",
      events: [
        TokenUsageEvent(
          timestamp: Date(timeIntervalSince1970: 1_700_000_000),
          inputTokens: 100,
          cachedInputTokens: 90,
          outputTokens: 10
        )
      ]
    )
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { [current.value] },
      fingerprintFile: { _ in current.value.fingerprint },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
        return parsed
      },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)
    current.value = archived
    _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(parseCount.value == 1)
  }

  @Test
  func fileChangingDuringBothParseAttemptsIsNotCached() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let fingerprints = LockedBox([
      CodexSessionFileFingerprint(
        path: initial.fingerprint.path,
        resourceIdentifier: "resource-1",
        size: 110,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_010)
      ),
      CodexSessionFileFingerprint(
        path: initial.fingerprint.path,
        resourceIdentifier: "resource-1",
        size: 120,
        modificationDate: Date(timeIntervalSince1970: 1_700_000_020)
      ),
    ])
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { [initial] },
      fingerprintFile: { _ in
        fingerprints.withValue { $0.removeFirst() }
      },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
        return ParsedCodexSessionFile(sessionID: "session-1", events: [])
      },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    let result = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(parseCount.value == 2)
    #expect(result.issues == [.skippedFiles(1)])
    #expect(result.snapshot?.hasUsageData == false)
  }

  @Test
  func fileChangingOnceUsesTheSecondStableParse() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let stable = CodexSessionFileFingerprint(
      path: initial.fingerprint.path,
      resourceIdentifier: "resource-1",
      size: 110,
      modificationDate: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let fingerprints = LockedBox([stable, stable])
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { [initial] },
      fingerprintFile: { _ in
        fingerprints.withValue { $0.removeFirst() }
      },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
        let input = parseCount.value * 100
        return ParsedCodexSessionFile(
          sessionID: "session-1",
          events: [
            TokenUsageEvent(
              timestamp: Date(timeIntervalSince1970: 1_700_000_000),
              inputTokens: input,
              cachedInputTokens: 0,
              outputTokens: 10
            )
          ]
        )
      },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    let result = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(parseCount.value == 2)
    #expect(result.issues.isEmpty)
    #expect(result.snapshot?.metrics(for: .day).totalTokens == 210)
  }

  @Test
  func newFileParseFailureIsSkippedAndRetriedLater() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let shouldFail = LockedBox(true)
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { [file] },
      fingerprintFile: { _ in file.fingerprint },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
        if shouldFail.value {
          throw CocoaError(.fileReadCorruptFile)
        }
        return ParsedCodexSessionFile(
          sessionID: "session-1",
          events: [
            TokenUsageEvent(
              timestamp: Date(timeIntervalSince1970: 1_700_000_000),
              inputTokens: 100,
              cachedInputTokens: 0,
              outputTokens: 10
            )
          ]
        )
      },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )
    let timeZone = TimeZone(secondsFromGMT: 0)!

    let failed = await repository.refresh(timeZone: timeZone)
    shouldFail.value = false
    let recovered = await repository.refresh(timeZone: timeZone)

    #expect(failed.snapshot?.hasUsageData == false)
    #expect(failed.issues == [.skippedFiles(1)])
    #expect(recovered.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(recovered.issues.isEmpty)
    #expect(parseCount.value == 2)
  }

  @Test
  func modifiedFileParseFailureKeepsOldRecordAndRetriesLater() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let modified = descriptor(
      path: original.fingerprint.path,
      resource: "resource-1",
      size: 120,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    let current = LockedBox(original)
    let shouldFail = LockedBox(false)
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { [current.value] },
      fingerprintFile: { _ in current.value.fingerprint },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
        if shouldFail.value {
          throw CocoaError(.fileReadCorruptFile)
        }
        return ParsedCodexSessionFile(
          sessionID: "session-1",
          events: [
            TokenUsageEvent(
              timestamp: Date(timeIntervalSince1970: 1_700_000_000),
              inputTokens: 100,
              cachedInputTokens: 90,
              outputTokens: 10
            )
          ]
        )
      },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)
    current.value = modified
    shouldFail.value = true
    let firstFailure = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)
    let secondFailure = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(firstFailure.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(secondFailure.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(firstFailure.issues == [.skippedFiles(1)])
    #expect(secondFailure.issues == [.skippedFiles(1)])
    #expect(parseCount.value == 3)
  }

  @Test
  func cacheWriteFailureKeepsTheInMemorySnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedDirectory = root.appending(path: "not-a-directory")
    try Data("file".utf8).write(to: blockedDirectory)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: blockedDirectory),
      discoverFiles: { [] },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    let result = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(result.snapshot != nil)
    #expect(result.issues == [.cacheWriteFailed])
  }

  @Test
  func overlappingRefreshesShareTheInFlightDiscovery() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let allowDiscoveryToFinish = DispatchSemaphore(value: 0)
    let discoveryCount = LockedBox(0)
    let secondCallStarted = LockedBox(false)
    let timeZone = TimeZone(secondsFromGMT: 0)!
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: {
        let invocation = discoveryCount.withValue {
          $0 += 1
          return $0
        }
        if invocation == 1 {
          allowDiscoveryToFinish.wait()
        }
        return []
      },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )
    let first = Task {
      await repository.refresh(timeZone: timeZone)
    }
    while discoveryCount.value == 0 {
      await Task.yield()
    }
    let second = Task {
      secondCallStarted.value = true
      return await repository.refresh(timeZone: timeZone)
    }
    while !secondCallStarted.value {
      await Task.yield()
    }
    _ = await repository.cachedSnapshot(timeZone: timeZone)

    allowDiscoveryToFinish.signal()
    let firstResult = await first.value
    let secondResult = await second.value

    #expect(discoveryCount.value == 1)
    #expect(secondResult == firstResult)
  }

  @Test
  func sourceFailureAfterCacheWriteFailureKeepsLastGoodSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedDirectory = root.appending(path: "not-a-directory")
    try Data("file".utf8).write(to: blockedDirectory)
    let discoveryError = LockedBox<Error?>(nil)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: blockedDirectory),
      discoverFiles: {
        if let error = discoveryError.value { throw error }
        return []
      },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )
    let timeZone = TimeZone(secondsFromGMT: 0)!

    let first = await repository.refresh(timeZone: timeZone)
    discoveryError.value = CocoaError(.fileReadNoPermission)
    let failed = await repository.refresh(timeZone: timeZone)
    let cached = await repository.cachedSnapshot(timeZone: timeZone)

    #expect(first.snapshot != nil)
    #expect(first.issues == [.cacheWriteFailed])
    #expect(failed.snapshot == first.snapshot)
    #expect(failed.issues == [.sourceUnavailable])
    #expect(cached == first.snapshot)
  }

  @Test
  func skippedFileWarningPrecedesCacheWriteWarning() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedDirectory = root.appending(path: "not-a-directory")
    try Data("file".utf8).write(to: blockedDirectory)
    let file = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: blockedDirectory),
      discoverFiles: { [file] },
      fingerprintFile: { _ in file.fingerprint },
      parseFile: { _ in throw CocoaError(.fileReadCorruptFile) },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    let result = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(result.issues == [.skippedFiles(1), .cacheWriteFailed])
  }

  @Test
  @MainActor
  func refreshRunsInjectedSourceWorkOutsideMainThread() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mainThreadChecks = LockedBox<[Bool]>([])
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: {
        mainThreadChecks.update { $0.append(Thread.isMainThread) }
        return []
      },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )

    _ = await repository.refresh(timeZone: TimeZone(secondsFromGMT: 0)!)

    #expect(mainThreadChecks.value == [false])
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) {
    storage = value
  }

  var value: Value {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }

  func update(_ body: (inout Value) -> Void) {
    lock.withLock { body(&storage) }
  }

  func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.withLock { body(&storage) }
  }
}

private struct RepositoryTestContext {
  let root: URL
  let file: URL
  let timeZone = TimeZone(secondsFromGMT: 0)!
  let parseCount: LockedBox<Int>
  let discoveryError: LockedBox<Error?>
  let repository: TokenUsageRepository

  init() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let fileURL = rootURL.appending(path: "sessions/2026/07/28/session.jsonl")
    let parseCounter = LockedBox(0)
    let errorBox = LockedBox<Error?>(nil)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let scanner = CodexSessionScanner()
    root = rootURL
    file = fileURL
    parseCount = parseCounter
    discoveryError = errorBox
    repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(
        directoryURL: rootURL.appending(path: "cache", directoryHint: .isDirectory)
      ),
      discoverFiles: {
        if let error = errorBox.value { throw error }
        return try scanner.discoverFiles(codexHome: rootURL)
      },
      fingerprintFile: { try scanner.fingerprint(for: $0) },
      parseFile: {
        parseCounter.update { $0 += 1 }
        return try scanner.parseFile(at: $0)
      },
      now: { ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")! }
    )
  }

  func writeSession(
    input: Int,
    output: Int,
    modifiedAt: TimeInterval = 1_700_000_000
  ) throws {
    let contents = """
      {"timestamp":"2026-07-28T00:00:00Z","type":"session_meta","payload":{"session_id":"session-1"}}
      {"timestamp":"2026-07-28T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"output_tokens":\(output)}}}}
      """
    try Data(contents.utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: modifiedAt)],
      ofItemAtPath: file.path
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func descriptor(
  path: String,
  resource: String,
  size: Int64,
  modifiedAt: Date
) -> CodexSessionFileDescriptor {
  CodexSessionFileDescriptor(
    url: URL(filePath: path),
    fingerprint: CodexSessionFileFingerprint(
      path: path,
      resourceIdentifier: resource,
      size: size,
      modificationDate: modifiedAt
    )
  )
}
