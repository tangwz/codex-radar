import Foundation
import OSLog

final class ConsumedResetSignalStore {
  private let baselineKey = "hasResetSignalBaseline"
  private let consumedIDsKey = "consumedResetSignalIDs"
  private let legacyLastIDKey = "lastObservedResetSignalID"

  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "reset-notifications"
  )

  private let defaults: UserDefaults
  private var loadedConsumedIDs: Set<String>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var hasBaseline: Bool {
    loadConsumedIDsIfNeeded()
    return defaults.bool(forKey: baselineKey)
  }

  var consumedSignalIDs: Set<String> {
    loadConsumedIDsIfNeeded()
    return loadedConsumedIDs!
  }

  func contains(_ signalID: String) -> Bool {
    loadConsumedIDsIfNeeded()
    return loadedConsumedIDs!.contains(signalID)
  }

  func establishBaseline(signalID: String?) {
    loadConsumedIDsIfNeeded()
    defaults.set(true, forKey: baselineKey)

    if let signalID {
      loadedConsumedIDs!.insert(signalID)
    }
    persist(loadedConsumedIDs!)
  }

  func consume(_ signalID: String) {
    loadConsumedIDsIfNeeded()
    guard loadedConsumedIDs!.insert(signalID).inserted else { return }
    persist(loadedConsumedIDs!)
  }

  private func loadConsumedIDsIfNeeded() {
    guard loadedConsumedIDs == nil else { return }

    var consumedIDs: Set<String>
    var shouldPersist = false

    if let data = defaults.data(forKey: consumedIDsKey) {
      do {
        consumedIDs = Set(try JSONDecoder().decode([String].self, from: data))
      } catch {
        Self.logger.error("Recovering corrupt consumed reset signal IDs")
        consumedIDs = []
        shouldPersist = true
      }
    } else {
      consumedIDs = []
      shouldPersist = defaults.object(forKey: consumedIDsKey) != nil
      if shouldPersist {
        Self.logger.error("Recovering corrupt consumed reset signal IDs")
      }
    }

    let legacyID = defaults.string(forKey: legacyLastIDKey)
    if let legacyID {
      consumedIDs.insert(legacyID)
      shouldPersist = true
    }

    loadedConsumedIDs = consumedIDs

    guard shouldPersist, persist(consumedIDs) else { return }
    if legacyID != nil {
      defaults.removeObject(forKey: legacyLastIDKey)
    }
  }

  @discardableResult
  private func persist(_ consumedIDs: Set<String>) -> Bool {
    do {
      let data = try JSONEncoder().encode(consumedIDs.sorted())
      defaults.set(data, forKey: consumedIDsKey)
      return true
    } catch {
      Self.logger.error("Unable to persist consumed reset signal IDs")
      return false
    }
  }
}
