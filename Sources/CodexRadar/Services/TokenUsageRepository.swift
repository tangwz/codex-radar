import Foundation

enum TokenUsageRepositoryIssue: Equatable, Sendable {
  case sourceUnavailable
  case skippedFiles(Int)
  case cacheWriteFailed
}

struct TokenUsageRepositoryResult: Equatable, Sendable {
  let snapshot: TokenUsageSnapshot?
  let issues: [TokenUsageRepositoryIssue]
}

actor TokenUsageRepository {
  typealias DiscoverFiles = @Sendable () throws -> [CodexSessionFileDescriptor]
  typealias FingerprintFile =
    @Sendable (URL) throws -> CodexSessionFileFingerprint
  typealias ParseFile = @Sendable (URL) throws -> ParsedCodexSessionFile
  typealias Now = @Sendable () -> Date

  private let cacheStore: TokenUsageCacheStore
  private let discoverFiles: DiscoverFiles
  private let fingerprintFile: FingerprintFile
  private let parseFile: ParseFile
  private let now: Now
  private var inFlight: RefreshFlight?
  private var pendingRefreshes: [PendingRefresh] = []
  private var lastSnapshot: TokenUsageSnapshot?
  private var nextGeneration = 0

  private struct RefreshFlight {
    let generation: Int
    let timeZoneIdentifier: String
    var waiters: [CheckedContinuation<TokenUsageRepositoryResult, Never>]
  }

  private struct PendingRefresh {
    let generation: Int
    let timeZone: TimeZone
    var waiters: [CheckedContinuation<TokenUsageRepositoryResult, Never>]
  }

  init(
    codexHome: URL = CodexSessionScanner.defaultCodexHome(),
    cacheStore: TokenUsageCacheStore = TokenUsageCacheStore(),
    scanner: CodexSessionScanner = CodexSessionScanner(),
    now: @escaping Now = Date.init
  ) {
    self.cacheStore = cacheStore
    discoverFiles = { try scanner.discoverFiles(codexHome: codexHome) }
    fingerprintFile = { try scanner.fingerprint(for: $0) }
    parseFile = { try scanner.parseFile(at: $0) }
    self.now = now
  }

  init(
    cacheStore: TokenUsageCacheStore,
    discoverFiles: @escaping DiscoverFiles,
    fingerprintFile: @escaping FingerprintFile,
    parseFile: @escaping ParseFile,
    now: @escaping Now
  ) {
    self.cacheStore = cacheStore
    self.discoverFiles = discoverFiles
    self.fingerprintFile = fingerprintFile
    self.parseFile = parseFile
    self.now = now
  }

  func cachedSnapshot(timeZone: TimeZone) -> TokenUsageSnapshot? {
    if let lastSnapshot,
      lastSnapshot.timeZoneIdentifier == timeZone.identifier
    {
      return lastSnapshot
    }
    guard
      let snapshot = try? cacheStore.loadSnapshot(),
      snapshot.timeZoneIdentifier == timeZone.identifier
    else {
      return nil
    }
    lastSnapshot = snapshot
    return snapshot
  }

  func refresh(timeZone: TimeZone) async -> TokenUsageRepositoryResult {
    await withCheckedContinuation { continuation in
      enqueueRefresh(timeZone: timeZone, continuation: continuation)
    }
  }

  private func enqueueRefresh(
    timeZone: TimeZone,
    continuation: CheckedContinuation<TokenUsageRepositoryResult, Never>
  ) {
    if let lastIndex = pendingRefreshes.indices.last,
      pendingRefreshes[lastIndex].timeZone.identifier == timeZone.identifier
    {
      pendingRefreshes[lastIndex].waiters.append(continuation)
      return
    }
    if pendingRefreshes.isEmpty,
      var inFlight,
      inFlight.timeZoneIdentifier == timeZone.identifier
    {
      inFlight.waiters.append(continuation)
      self.inFlight = inFlight
      return
    }

    let generation = nextGeneration
    nextGeneration += 1
    pendingRefreshes.append(
      PendingRefresh(
        generation: generation,
        timeZone: timeZone,
        waiters: [continuation]
      )
    )
    startNextRefreshIfNeeded()
  }

  private func startNextRefreshIfNeeded() {
    guard inFlight == nil, !pendingRefreshes.isEmpty else { return }
    let request = pendingRefreshes.removeFirst()
    let generation = request.generation
    let timeZone = request.timeZone
    let memorySnapshot =
      lastSnapshot?.timeZoneIdentifier == timeZone.identifier
      ? lastSnapshot
      : nil
    let cacheStore = cacheStore
    let discoverFiles = discoverFiles
    let fingerprintFile = fingerprintFile
    let parseFile = parseFile
    let now = now
    let task = Task.detached {
      Self.performRefresh(
        timeZone: timeZone,
        memorySnapshot: memorySnapshot,
        cacheStore: cacheStore,
        discoverFiles: discoverFiles,
        fingerprintFile: fingerprintFile,
        parseFile: parseFile,
        now: now
      )
    }
    inFlight = RefreshFlight(
      generation: generation,
      timeZoneIdentifier: timeZone.identifier,
      waiters: request.waiters
    )
    Task { [weak self] in
      let result = await task.value
      await self?.finish(generation: generation, with: result)
    }
  }

  private func finish(
    generation: Int,
    with result: TokenUsageRepositoryResult
  ) {
    guard let completed = inFlight, completed.generation == generation else {
      return
    }
    inFlight = nil
    if let snapshot = result.snapshot {
      lastSnapshot = snapshot
    }
    startNextRefreshIfNeeded()
    for waiter in completed.waiters {
      waiter.resume(returning: result)
    }
  }

  private static func performRefresh(
    timeZone: TimeZone,
    memorySnapshot: TokenUsageSnapshot?,
    cacheStore: TokenUsageCacheStore,
    discoverFiles: DiscoverFiles,
    fingerprintFile: FingerprintFile,
    parseFile: ParseFile,
    now: Now
  ) -> TokenUsageRepositoryResult {
    let previousManifest: TokenUsageManifest?
    do {
      previousManifest = try cacheStore.loadManifest()
    } catch {
      previousManifest = nil
    }
    let fallbackSnapshot = fallbackSnapshot(
      manifest: previousManifest,
      timeZone: timeZone,
      memorySnapshot: memorySnapshot,
      cacheStore: cacheStore,
      now: now
    )

    let descriptors: [CodexSessionFileDescriptor]
    do {
      descriptors = try discoverFiles()
    } catch {
      return TokenUsageRepositoryResult(
        snapshot: fallbackSnapshot,
        issues: [.sourceUnavailable]
      )
    }

    let previousMatches = matchedPreviousRecords(
      for: descriptors,
      previousRecords: previousManifest?.files ?? []
    )
    var records: [CodexSessionFileRecord] = []
    var skippedFileCount = 0

    for (index, descriptor) in descriptors.enumerated() {
      let previous = previousMatches[index]
      if let previous,
        previous.fingerprint.hasSameContent(as: descriptor.fingerprint)
      {
        records.append(
          CodexSessionFileRecord(
            fingerprint: descriptor.fingerprint,
            sessionID: previous.sessionID,
            events: previous.events
          )
        )
        continue
      }

      do {
        records.append(
          try stableRecord(
            for: descriptor,
            fingerprintFile: fingerprintFile,
            parseFile: parseFile
          )
        )
      } catch {
        skippedFileCount += 1
        if let previous {
          records.append(previous)
        }
      }
    }

    records.sort { $0.fingerprint.path < $1.fingerprint.path }
    let events = CodexSessionScanner.deduplicatedEvents(from: records)
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: events,
      at: now(),
      timeZone: timeZone
    )
    let manifest = TokenUsageManifest(files: records)
    var issues: [TokenUsageRepositoryIssue] = []
    if skippedFileCount > 0 {
      issues.append(.skippedFiles(skippedFileCount))
    }

    do {
      try cacheStore.saveManifest(manifest)
      try cacheStore.saveSnapshot(snapshot)
    } catch {
      issues.append(.cacheWriteFailed)
    }
    return TokenUsageRepositoryResult(snapshot: snapshot, issues: issues)
  }

  private static func matchedPreviousRecords(
    for descriptors: [CodexSessionFileDescriptor],
    previousRecords: [CodexSessionFileRecord]
  ) -> [CodexSessionFileRecord?] {
    var matches = Array<CodexSessionFileRecord?>(
      repeating: nil,
      count: descriptors.count
    )
    var remainingPreviousIndices = Set(previousRecords.indices)
    var previousByIdentity: [String: [Int]] = [:]
    var previousByPath: [String: [Int]] = [:]

    for index in previousRecords.indices.reversed() {
      let fingerprint = previousRecords[index].fingerprint
      previousByIdentity[fingerprint.cacheIdentity, default: []].append(index)
      previousByPath[normalizedPath(fingerprint.path), default: []].append(index)
    }

    for index in descriptors.indices {
      let identity = descriptors[index].fingerprint.cacheIdentity
      guard
        let previousIndex = takePreviousIndex(
          for: identity,
          from: &previousByIdentity,
          remainingIndices: &remainingPreviousIndices
        )
      else {
        continue
      }
      matches[index] = previousRecords[previousIndex]
    }

    for index in descriptors.indices where matches[index] == nil {
      let path = normalizedPath(descriptors[index].fingerprint.path)
      guard
        let previousIndex = takePreviousIndex(
          for: path,
          from: &previousByPath,
          remainingIndices: &remainingPreviousIndices
        )
      else {
        continue
      }
      matches[index] = previousRecords[previousIndex]
    }
    return matches
  }

  private static func takePreviousIndex(
    for key: String,
    from index: inout [String: [Int]],
    remainingIndices: inout Set<Int>
  ) -> Int? {
    while let candidate = index[key]?.popLast() {
      if index[key]?.isEmpty == true {
        index[key] = nil
      }
      if remainingIndices.remove(candidate) != nil {
        return candidate
      }
    }
    return nil
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(filePath: path).standardizedFileURL.path
  }

  private static func stableRecord(
    for descriptor: CodexSessionFileDescriptor,
    fingerprintFile: FingerprintFile,
    parseFile: ParseFile
  ) throws -> CodexSessionFileRecord {
    var expectedFingerprint = descriptor.fingerprint
    for _ in 0..<2 {
      let parsed = try parseFile(descriptor.url)
      let finalFingerprint = try fingerprintFile(descriptor.url)
      if expectedFingerprint.hasSameContent(as: finalFingerprint) {
        return CodexSessionFileRecord(
          fingerprint: finalFingerprint,
          sessionID: parsed.sessionID,
          events: parsed.events
        )
      }
      expectedFingerprint = finalFingerprint
    }
    throw CocoaError(.fileReadUnknown)
  }

  private static func fallbackSnapshot(
    manifest: TokenUsageManifest?,
    timeZone: TimeZone,
    memorySnapshot: TokenUsageSnapshot?,
    cacheStore: TokenUsageCacheStore,
    now: Now
  ) -> TokenUsageSnapshot? {
    if let memorySnapshot {
      return memorySnapshot
    }
    if let cached = try? cacheStore.loadSnapshot(),
      cached.timeZoneIdentifier == timeZone.identifier
    {
      return cached
    }
    guard let manifest else { return nil }
    return TokenUsageSnapshotBuilder.make(
      events: CodexSessionScanner.deduplicatedEvents(from: manifest.files),
      at: now(),
      timeZone: timeZone
    )
  }
}
