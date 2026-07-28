import Foundation

struct TokenUsageCacheStore: Sendable {
  let directoryURL: URL

  var snapshotURL: URL {
    directoryURL.appending(path: "token-usage-snapshot-v1.plist")
  }

  var manifestURL: URL {
    directoryURL.appending(path: "token-usage-manifest-v1.plist")
  }

  init(directoryURL: URL = Self.defaultDirectory()) {
    self.directoryURL = directoryURL
  }

  func loadSnapshot() throws -> TokenUsageSnapshot? {
    guard let snapshot: TokenUsageSnapshot = try decodeIfPresent(from: snapshotURL) else {
      return nil
    }
    return snapshot.isCompatible ? snapshot : nil
  }

  func loadManifest() throws -> TokenUsageManifest? {
    guard let manifest: TokenUsageManifest = try decodeIfPresent(from: manifestURL) else {
      return nil
    }
    return manifest.isCompatible ? manifest : nil
  }

  func saveSnapshot(_ snapshot: TokenUsageSnapshot) throws {
    try encode(snapshot, to: snapshotURL)
  }

  func saveManifest(_ manifest: TokenUsageManifest) throws {
    try encode(manifest, to: manifestURL)
  }

  static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appending(
      path: "com.terence.codex-radar/token-usage",
      directoryHint: .isDirectory
    )
  }

  private func decodeIfPresent<Value: Decodable>(
    from url: URL
  ) throws -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try PropertyListDecoder().decode(Value.self, from: Data(contentsOf: url))
    } catch {
      return nil
    }
  }

  private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(value).write(to: url, options: .atomic)
  }
}
