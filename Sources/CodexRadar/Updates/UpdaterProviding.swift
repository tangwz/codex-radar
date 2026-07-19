import CoreFoundation
import Foundation
import SwiftUI

@MainActor
protocol UpdaterProviding: AnyObject {
  var isAvailable: Bool { get }
  var unavailableReasonKey: String? { get }
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var canCheckForUpdates: Bool { get }
  func checkForUpdates()
}

@MainActor
final class UpdaterSettingsModel: ObservableObject {
  @Published private(set) var isAvailable: Bool
  @Published private(set) var unavailableReasonKey: String?
  @Published private(set) var automaticUpdatesEnabled: Bool
  @Published private(set) var canCheckForUpdates: Bool

  private let provider: any UpdaterProviding

  init(provider: any UpdaterProviding) {
    self.provider = provider
    isAvailable = provider.isAvailable
    unavailableReasonKey = provider.unavailableReasonKey
    automaticUpdatesEnabled = provider.automaticallyChecksForUpdates
      && provider.automaticallyDownloadsUpdates
    canCheckForUpdates = provider.canCheckForUpdates
  }

  func setAutomaticUpdatesEnabled(_ enabled: Bool) {
    provider.automaticallyChecksForUpdates = enabled
    provider.automaticallyDownloadsUpdates = enabled
    refresh()
  }

  func checkForUpdates() {
    guard provider.isAvailable, provider.canCheckForUpdates else { return }
    provider.checkForUpdates()
    refresh()
  }

  func refresh() {
    isAvailable = provider.isAvailable
    unavailableReasonKey = provider.unavailableReasonKey
    automaticUpdatesEnabled = provider.automaticallyChecksForUpdates
      && provider.automaticallyDownloadsUpdates
    canCheckForUpdates = provider.canCheckForUpdates
  }
}

@MainActor
final class DisabledUpdaterController: UpdaterProviding {
  let isAvailable = false
  let unavailableReasonKey: String?
  var automaticallyChecksForUpdates: Bool {
    get { false }
    set {}
  }
  var automaticallyDownloadsUpdates: Bool {
    get { false }
    set {}
  }
  let canCheckForUpdates = false

  init(unavailableReasonKey: String? = "Updates are available in release builds only.") {
    self.unavailableReasonKey = unavailableReasonKey
  }

  func checkForUpdates() {}
}

struct UpdateConfiguration: Sendable {
  static let enabledKey = "CodexRadarUpdatesEnabled"

  let updatesEnabled: Bool

  init(bundle: Bundle) {
    self.init(infoDictionary: bundle.infoDictionary ?? [:])
  }

  init(infoDictionary: [String: Any]) {
    guard let value = infoDictionary[Self.enabledKey] as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID()
    else {
      updatesEnabled = false
      return
    }

    updatesEnabled = value.boolValue
  }
}

@MainActor
enum UpdaterFactory {
  static func make(bundle: Bundle) -> any UpdaterProviding {
    guard UpdateConfiguration(bundle: bundle).updatesEnabled else {
      return DisabledUpdaterController()
    }

    return DisabledUpdaterController(unavailableReasonKey: "Updates are not initialized.")
  }
}
