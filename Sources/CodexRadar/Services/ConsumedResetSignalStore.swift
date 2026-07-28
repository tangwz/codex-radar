import Foundation
import OSLog

final class ConsumedResetSignalStore {
  struct ObservationState {
    let hasBaseline: Bool
    let consumedSignalIDs: Set<String>
  }

  private let baselineKey = "hasResetSignalBaseline"
  private let consumedIDsKey = "consumedResetSignalIDs"
  private let legacyLastIDKey = "lastObservedResetSignalID"

  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "reset-notifications"
  )

  private let defaults: UserDefaults
  private var loadedConsumedIDs: Set<String>?
  private var needsBaselineMigration: Bool

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    needsBaselineMigration =
      defaults.bool(forKey: baselineKey)
      && defaults.object(forKey: consumedIDsKey) == nil
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

  func stateForObservation(currentSignalID: String?) -> ObservationState {
    loadConsumedIDsIfNeeded(
      corruptionRecoverySignalID: currentSignalID
    )
    if needsBaselineMigration {
      if let currentSignalID {
        loadedConsumedIDs!.insert(currentSignalID)
      }
      if persist(loadedConsumedIDs!) {
        needsBaselineMigration = false
      }
    }
    return ObservationState(
      hasBaseline: defaults.bool(forKey: baselineKey),
      consumedSignalIDs: loadedConsumedIDs!
    )
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

  private func loadConsumedIDsIfNeeded(
    corruptionRecoverySignalID: String? = nil
  ) {
    guard loadedConsumedIDs == nil else { return }

    var consumedIDs: Set<String>
    var shouldPersist = false
    var recoveredCorruption = false

    if let data = defaults.data(forKey: consumedIDsKey) {
      do {
        consumedIDs = Set(try JSONDecoder().decode([String].self, from: data))
      } catch {
        Self.logger.error("Recovering corrupt consumed reset signal IDs")
        consumedIDs = []
        shouldPersist = true
        recoveredCorruption = true
      }
    } else {
      consumedIDs = []
      shouldPersist = defaults.object(forKey: consumedIDsKey) != nil
      if shouldPersist {
        Self.logger.error("Recovering corrupt consumed reset signal IDs")
        recoveredCorruption = true
      }
    }

    let legacyID = defaults.string(forKey: legacyLastIDKey)
    if let legacyID {
      consumedIDs.insert(legacyID)
      shouldPersist = true
    }

    if recoveredCorruption, let corruptionRecoverySignalID {
      consumedIDs.insert(corruptionRecoverySignalID)
    }

    loadedConsumedIDs = consumedIDs

    if shouldPersist, persist(consumedIDs), legacyID != nil {
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
