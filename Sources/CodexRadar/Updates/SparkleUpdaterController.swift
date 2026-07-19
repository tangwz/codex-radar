import AppKit
import Foundation
import OSLog
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate {
  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "updates"
  )

  let isAvailable = true
  let unavailableReasonKey: String? = nil

  var automaticallyChecksForUpdates: Bool {
    get { standardUpdaterController.updater.automaticallyChecksForUpdates }
    set { standardUpdaterController.updater.automaticallyChecksForUpdates = newValue }
  }

  var automaticallyDownloadsUpdates: Bool {
    get { standardUpdaterController.updater.automaticallyDownloadsUpdates }
    set { standardUpdaterController.updater.automaticallyDownloadsUpdates = newValue }
  }

  var canCheckForUpdates: Bool {
    standardUpdaterController.updater.canCheckForUpdates
  }

  private let bundleURL: URL
  private let homeURL: URL
  private let isWritable: (URL) -> Bool
  private var isShowingInstallationAlert = false
  private lazy var standardUpdaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: self,
    userDriverDelegate: nil
  )

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    isWritable: @escaping (URL) -> Bool = {
      guard
        let resourceValues = try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
        let isReadOnly = resourceValues.volumeIsReadOnly
      else {
        return false
      }

      return !isReadOnly
    }
  ) {
    self.bundleURL = bundleURL
    self.homeURL = homeURL
    self.isWritable = isWritable
    super.init()
    _ = standardUpdaterController
  }

  func checkForUpdates() {
    let location = UpdateInstallationLocation.evaluate(
      bundleURL: bundleURL,
      homeURL: homeURL,
      isWritable: isWritable
    )

    guard location == .supported else {
      showUnsupportedInstallationAlert()
      return
    }

    standardUpdaterController.checkForUpdates(nil)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    let error = error as NSError
    Self.logger.error(
      "Sparkle update aborted: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
    )
  }

  private func showUnsupportedInstallationAlert() {
    guard !isShowingInstallationAlert else { return }
    isShowingInstallationAlert = true
    defer { isShowingInstallationAlert = false }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "CodexRadar cannot install updates from its current location."
    alert.informativeText =
      "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
