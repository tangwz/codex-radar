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
    #expect(refreshed.issues.isEmpty)
  }

  @Test
  func cachedFingerprintDiscoveryFailureRetainsItsRecord() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = descriptor(
      path: "/tmp/sessions/cached.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let discovery = LockedBox(
      CodexSessionDiscovery(files: [file])
    )
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { discovery.value },
      fingerprintFile: { _ in file.fingerprint },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
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

    _ = await repository.refresh(timeZone: timeZone)
    discovery.value = CodexSessionDiscovery(
      files: [],
      failedPaths: [file.fingerprint.path]
    )
    let failed = await repository.refresh(timeZone: timeZone)

    #expect(failed.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(failed.issues == [.skippedFiles(1)])
    #expect(parseCount.value == 1)
  }

  @Test
  func failedPathDoesNotDuplicateARecordReusedByResourceIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let active = descriptor(
      path: "/tmp/sessions/moved.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let archived = descriptor(
      path: "/tmp/archived_sessions/moved.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let discovery = LockedBox(
      CodexSessionDiscovery(files: [active])
    )
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { discovery.value },
      fingerprintFile: { url in
        url == active.url ? active.fingerprint : archived.fingerprint
      },
      parseFile: { _ in
        ParsedCodexSessionFile(
          sessionID: nil,
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

    _ = await repository.refresh(timeZone: timeZone)
    discovery.value = CodexSessionDiscovery(
      files: [archived],
      failedPaths: [active.fingerprint.path]
    )
    let result = await repository.refresh(timeZone: timeZone)

    #expect(result.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(result.issues == [.skippedFiles(1)])
  }

  @Test
  func uncachedFingerprintDiscoveryFailureWarnsAndRetriesLater() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = descriptor(
      path: "/tmp/sessions/new.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let discovery = LockedBox(
      CodexSessionDiscovery(
        files: [],
        failedPaths: [file.fingerprint.path]
      )
    )
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { discovery.value },
      fingerprintFile: { _ in file.fingerprint },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
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
    discovery.value = CodexSessionDiscovery(files: [file])
    let recovered = await repository.refresh(timeZone: timeZone)

    #expect(failed.snapshot?.hasUsageData == false)
    #expect(failed.issues == [.skippedFiles(1)])
    #expect(recovered.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(recovered.issues.isEmpty)
    #expect(parseCount.value == 1)
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
      discoverFiles: { CodexSessionDiscovery(files: [current.value]) },
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
      discoverFiles: { CodexSessionDiscovery(files: [initial]) },
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
      discoverFiles: { CodexSessionDiscovery(files: [initial]) },
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
      discoverFiles: { CodexSessionDiscovery(files: [file]) },
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
  func replacedFileParseFailureKeepsPathMatchedRecordAndRetriesLater() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let replacement = descriptor(
      path: original.fingerprint.path,
      resource: "resource-2",
      size: 120,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    let current = LockedBox(original)
    let shouldFail = LockedBox(false)
    let parseCount = LockedBox(0)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { CodexSessionDiscovery(files: [current.value]) },
      fingerprintFile: { _ in current.value.fingerprint },
      parseFile: { _ in
        parseCount.update { $0 += 1 }
        if shouldFail.value {
          throw CocoaError(.fileReadCorruptFile)
        }
        let input = current.value.fingerprint.resourceIdentifier == "resource-1" ? 100 : 250
        return ParsedCodexSessionFile(
          sessionID: "session-1",
          events: [
            TokenUsageEvent(
              timestamp: Date(timeIntervalSince1970: 1_700_000_000),
              inputTokens: input,
              cachedInputTokens: 0,
              outputTokens: input / 10
            )
          ]
        )
      },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )
    let timeZone = TimeZone(secondsFromGMT: 0)!

    _ = await repository.refresh(timeZone: timeZone)
    current.value = replacement
    shouldFail.value = true
    let failed = await repository.refresh(timeZone: timeZone)
    shouldFail.value = false
    let recovered = await repository.refresh(timeZone: timeZone)

    #expect(failed.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(failed.issues == [.skippedFiles(1)])
    #expect(recovered.snapshot?.metrics(for: .day).totalTokens == 275)
    #expect(recovered.issues.isEmpty)
    #expect(parseCount.value == 3)
  }

  @Test
  func identityMatchPrecedesPathFallbackAndConsumesOldRecordOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = descriptor(
      path: "/tmp/sessions/session.jsonl",
      resource: "resource-1",
      size: 100,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let replacement = descriptor(
      path: original.fingerprint.path,
      resource: "resource-2",
      size: 120,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    let renamed = descriptor(
      path: "/tmp/archived_sessions/session.jsonl",
      resource: "resource-1",
      size: 120,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    let current = LockedBox([original])
    let shouldFail = LockedBox(false)
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: { CodexSessionDiscovery(files: current.value) },
      fingerprintFile: { url in
        try #require(current.value.first { $0.url == url }).fingerprint
      },
      parseFile: { _ in
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

    _ = await repository.refresh(timeZone: timeZone)
    current.value = [replacement, renamed]
    shouldFail.value = true
    let failed = await repository.refresh(timeZone: timeZone)

    #expect(failed.snapshot?.metrics(for: .day).totalTokens == 110)
    #expect(failed.issues == [.skippedFiles(2)])
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
      discoverFiles: { CodexSessionDiscovery(files: [current.value]) },
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
      discoverFiles: { CodexSessionDiscovery(files: []) },
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
        return CodexSessionDiscovery(files: [])
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
  func midnightCutoffQueuesAfterAnActivePreMidnightSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let beforeMidnight = Date(timeIntervalSince1970: 1_785_542_399)
    let midnight = Date(timeIntervalSince1970: 1_785_542_400)
    let afterMidnight = Date(timeIntervalSince1970: 1_785_542_401)
    let dates = LockedBox([
      beforeMidnight,
      beforeMidnight,
      afterMidnight,
      afterMidnight,
    ])
    let allowFirstDiscoveryToFinish = DispatchSemaphore(value: 0)
    let discoveryCount = LockedBox(0)
    let cutoffCallStarted = LockedBox(false)
    let timeZone = TimeZone(secondsFromGMT: 0)!
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: {
        let invocation = discoveryCount.withValue {
          $0 += 1
          return $0
        }
        if invocation == 1 {
          allowFirstDiscoveryToFinish.wait()
        }
        return CodexSessionDiscovery(files: [])
      },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: {
        dates.withValue { $0.removeFirst() }
      }
    )

    let preMidnight = Task {
      await repository.refresh(timeZone: timeZone)
    }
    while discoveryCount.value == 0 {
      await Task.yield()
    }
    let boundary = Task {
      cutoffCallStarted.value = true
      return await repository.refresh(
        timeZone: timeZone,
        freshnessCutoff: midnight
      )
    }
    while !cutoffCallStarted.value {
      await Task.yield()
    }
    _ = await repository.cachedSnapshot(timeZone: timeZone)

    allowFirstDiscoveryToFinish.signal()
    let preMidnightResult = await preMidnight.value
    let boundaryResult = await boundary.value

    #expect(discoveryCount.value == 2)
    #expect(preMidnightResult.snapshot?.generatedAt == beforeMidnight)
    #expect(boundaryResult.snapshot?.generatedAt == afterMidnight)
  }

  @Test
  func wakeCutoffQueuesAfterAnActivePreSleepSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let beforeSleep = Date(timeIntervalSince1970: 1_785_585_600)
    let wakeTime = Date(timeIntervalSince1970: 1_785_589_200)
    let afterWake = Date(timeIntervalSince1970: 1_785_589_201)
    let dates = LockedBox([
      beforeSleep,
      beforeSleep,
      afterWake,
      afterWake,
    ])
    let allowPreSleepDiscoveryToFinish = DispatchSemaphore(value: 0)
    let discoveryCount = LockedBox(0)
    let recoveryCallStarted = LockedBox(false)
    let timeZone = TimeZone(secondsFromGMT: 0)!
    let repository = TokenUsageRepository(
      cacheStore: TokenUsageCacheStore(directoryURL: directory),
      discoverFiles: {
        let invocation = discoveryCount.withValue {
          $0 += 1
          return $0
        }
        if invocation == 1 {
          allowPreSleepDiscoveryToFinish.wait()
        }
        return CodexSessionDiscovery(files: [])
      },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: {
        dates.withValue { $0.removeFirst() }
      }
    )

    let preSleep = Task {
      await repository.refresh(timeZone: timeZone)
    }
    while discoveryCount.value == 0 {
      await Task.yield()
    }
    let recovery = Task {
      recoveryCallStarted.value = true
      return await repository.refresh(
        timeZone: timeZone,
        freshnessCutoff: wakeTime
      )
    }
    while !recoveryCallStarted.value {
      await Task.yield()
    }
    _ = await repository.cachedSnapshot(timeZone: timeZone)

    allowPreSleepDiscoveryToFinish.signal()
    let preSleepResult = await preSleep.value
    let recoveryResult = await recovery.value

    #expect(discoveryCount.value == 2)
    #expect(preSleepResult.snapshot?.generatedAt == beforeSleep)
    #expect(recoveryResult.snapshot?.generatedAt == afterWake)
  }

  @Test
  func crossTimeZoneRefreshesCommitInFirstEntryOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gates = [
      DispatchSemaphore(value: 0),
      DispatchSemaphore(value: 0),
      DispatchSemaphore(value: 0),
    ]
    let discoveryCount = LockedBox(0)
    let secondCallStarted = LockedBox(false)
    let thirdCallStarted = LockedBox(false)
    let secondCallFinished = LockedBox(false)
    let thirdCallFinished = LockedBox(false)
    let cacheStore = TokenUsageCacheStore(directoryURL: directory)
    let repository = TokenUsageRepository(
      cacheStore: cacheStore,
      discoverFiles: {
        let invocation = discoveryCount.withValue {
          $0 += 1
          return $0
        }
        gates[invocation - 1].wait()
        return CodexSessionDiscovery(files: [])
      },
      fingerprintFile: { _ in throw CocoaError(.fileNoSuchFile) },
      parseFile: { _ in throw CocoaError(.fileNoSuchFile) },
      now: { Date(timeIntervalSince1970: 1_700_000_100) }
    )
    let firstTimeZone = TimeZone(secondsFromGMT: 0)!
    let secondTimeZone = TimeZone(identifier: "Asia/Shanghai")!
    let thirdTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    let first = Task {
      await repository.refresh(timeZone: firstTimeZone)
    }
    while discoveryCount.value < 1 {
      await Task.yield()
    }
    let second = Task(priority: .high) {
      secondCallStarted.value = true
      let result = await repository.refresh(timeZone: secondTimeZone)
      secondCallFinished.value = true
      return result
    }
    while !secondCallStarted.value {
      await Task.yield()
    }
    _ = await repository.cachedSnapshot(timeZone: firstTimeZone)
    let third = Task(priority: .background) {
      thirdCallStarted.value = true
      let result = await repository.refresh(timeZone: thirdTimeZone)
      thirdCallFinished.value = true
      return result
    }
    while !thirdCallStarted.value {
      await Task.yield()
    }
    _ = await repository.cachedSnapshot(timeZone: firstTimeZone)

    gates[0].signal()
    while discoveryCount.value < 2 {
      await Task.yield()
    }
    gates[1].signal()
    while !secondCallFinished.value && !thirdCallFinished.value {
      await Task.yield()
    }

    #expect(secondCallFinished.value)
    #expect(!thirdCallFinished.value)

    while discoveryCount.value < 3 {
      await Task.yield()
    }
    gates[2].signal()
    _ = await first.value
    let secondResult = await second.value
    let thirdResult = await third.value
    let loadedSnapshot = try cacheStore.loadSnapshot()
    let committed = try #require(loadedSnapshot)

    #expect(secondResult.snapshot?.timeZoneIdentifier == secondTimeZone.identifier)
    #expect(thirdResult.snapshot?.timeZoneIdentifier == thirdTimeZone.identifier)
    #expect(committed.timeZoneIdentifier == thirdTimeZone.identifier)
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
        return CodexSessionDiscovery(files: [])
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
      discoverFiles: { CodexSessionDiscovery(files: [file]) },
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
        return CodexSessionDiscovery(files: [])
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
