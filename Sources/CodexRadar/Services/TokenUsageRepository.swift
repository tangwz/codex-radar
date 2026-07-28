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
  private var lastSnapshot: TokenUsageSnapshot?
  private var nextGeneration = 0

  private struct RefreshFlight {
    let generation: Int
    let timeZoneIdentifier: String
    let task: Task<TokenUsageRepositoryResult, Never>
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
    if let inFlight {
      let result = await inFlight.task.value
      finish(inFlight, with: result)
      if inFlight.timeZoneIdentifier == timeZone.identifier {
        return result
      }
      return await refresh(timeZone: timeZone)
    }

    let generation = nextGeneration
    nextGeneration += 1
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
    let flight = RefreshFlight(
      generation: generation,
      timeZoneIdentifier: timeZone.identifier,
      task: task
    )
    inFlight = flight
    let result = await task.value
    finish(flight, with: result)
    return result
  }

  private func finish(
    _ flight: RefreshFlight,
    with result: TokenUsageRepositoryResult
  ) {
    guard inFlight?.generation == flight.generation else { return }
    inFlight = nil
    if let snapshot = result.snapshot {
      lastSnapshot = snapshot
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

    var previousByIdentity: [String: CodexSessionFileRecord] = [:]
    for record in previousManifest?.files ?? [] {
      previousByIdentity[record.fingerprint.cacheIdentity] = record
    }
    var records: [CodexSessionFileRecord] = []
    var skippedFileCount = 0

    for descriptor in descriptors {
      let identity = descriptor.fingerprint.cacheIdentity
      let previous = previousByIdentity.removeValue(forKey: identity)
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
