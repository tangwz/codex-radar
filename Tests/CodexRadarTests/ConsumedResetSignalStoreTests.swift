import Foundation
import Testing

@testable import CodexRadar

struct ConsumedResetSignalStoreTests {
  @Test
  func preservesEveryConsumedSignalID() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConsumedResetSignalStore(defaults: defaults)

    store.establishBaseline(signalID: "200")
    store.consume("100")
    store.consume("300")

    #expect(store.contains("100"))
    #expect(store.contains("200"))
    #expect(store.contains("300"))
  }

  @Test
  func writesConsumedIDsAsStableSortedJSONArray() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConsumedResetSignalStore(defaults: defaults)

    store.consume("300")
    store.consume("100")
    store.consume("200")

    let data = try #require(defaults.data(forKey: "consumedResetSignalIDs"))
    let storedIDs = try JSONDecoder().decode([String].self, from: data)

    #expect(storedIDs == ["100", "200", "300"])
  }

  @Test
  func establishesAnEmptyBaselineWithoutConsumingAnID() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConsumedResetSignalStore(defaults: defaults)

    #expect(!store.hasBaseline)

    store.establishBaseline(signalID: nil)

    #expect(store.hasBaseline)
    #expect(!store.contains("100"))
  }

  @Test
  func migratesLegacyLastSignalIDIntoTheConsumedSet() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "hasResetSignalBaseline")
    defaults.set("200", forKey: "lastObservedResetSignalID")

    let store = ConsumedResetSignalStore(defaults: defaults)

    #expect(store.hasBaseline)
    #expect(store.contains("200"))
    #expect(defaults.object(forKey: "lastObservedResetSignalID") == nil)

    let data = try #require(defaults.data(forKey: "consumedResetSignalIDs"))
    #expect(try JSONDecoder().decode([String].self, from: data) == ["200"])
  }

  @Test
  func migrationIsIdempotent() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("200", forKey: "lastObservedResetSignalID")

    let firstStore = ConsumedResetSignalStore(defaults: defaults)
    #expect(firstStore.contains("200"))

    let secondStore = ConsumedResetSignalStore(defaults: defaults)
    #expect(secondStore.contains("200"))

    let data = try #require(defaults.data(forKey: "consumedResetSignalIDs"))
    #expect(try JSONDecoder().decode([String].self, from: data) == ["200"])
  }

  @Test
  func recoversCorruptConsumedIDsFromTheLegacyID() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "hasResetSignalBaseline")
    defaults.set(Data("invalid".utf8), forKey: "consumedResetSignalIDs")
    defaults.set("200", forKey: "lastObservedResetSignalID")

    let store = ConsumedResetSignalStore(defaults: defaults)
    store.establishBaseline(signalID: "100")

    #expect(store.hasBaseline)
    #expect(store.contains("100"))
    #expect(store.contains("200"))
    #expect(defaults.object(forKey: "lastObservedResetSignalID") == nil)

    let data = try #require(defaults.data(forKey: "consumedResetSignalIDs"))
    #expect(try JSONDecoder().decode([String].self, from: data) == ["100", "200"])
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suiteName = "ConsumedResetSignalStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}
