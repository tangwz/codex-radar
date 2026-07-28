import Foundation
import Testing

@testable import CodexRadar

struct TokenUsageCacheStoreTests {
  @Test
  func roundTripsCompatibleSnapshotAndManifest() throws {
    let context = try CacheTestContext()
    defer { context.remove() }
    let snapshot = TokenUsageSnapshotBuilder.make(
      events: [],
      at: Date(timeIntervalSince1970: 1_700_000_000),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let manifest = TokenUsageManifest(files: [])

    try context.store.saveManifest(manifest)
    try context.store.saveSnapshot(snapshot)

    #expect(try context.store.loadManifest() == manifest)
    #expect(try context.store.loadSnapshot() == snapshot)
  }

  @Test
  func treatsCorruptFilesAsCacheMisses() throws {
    let context = try CacheTestContext()
    defer { context.remove() }
    try Data("broken".utf8).write(to: context.store.snapshotURL)
    try Data("broken".utf8).write(to: context.store.manifestURL)

    #expect(try context.store.loadSnapshot() == nil)
    #expect(try context.store.loadManifest() == nil)
  }

  @Test
  func treatsIncompatibleVersionsAsCacheMisses() throws {
    let context = try CacheTestContext()
    defer { context.remove() }
    let compatible = TokenUsageSnapshotBuilder.make(
      events: [],
      at: Date(timeIntervalSince1970: 1_700_000_000),
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let incompatible = TokenUsageSnapshot(
      schemaVersion: 999,
      parserVersion: compatible.parserVersion,
      generatedAt: compatible.generatedAt,
      timeZoneIdentifier: compatible.timeZoneIdentifier,
      hasUsageData: compatible.hasUsageData,
      dailyBuckets: compatible.dailyBuckets,
      monthlyBuckets: compatible.monthlyBuckets,
      yearlyBuckets: compatible.yearlyBuckets
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(incompatible).write(
      to: context.store.snapshotURL,
      options: .atomic
    )

    #expect(try context.store.loadSnapshot() == nil)
  }
}

private struct CacheTestContext {
  let directory: URL
  let store: TokenUsageCacheStore

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    store = TokenUsageCacheStore(directoryURL: directory)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
