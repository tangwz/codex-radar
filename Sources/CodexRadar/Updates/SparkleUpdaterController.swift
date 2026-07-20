import AppKit
import Foundation
import OSLog
import Sparkle

struct UpdateInstallationAlertContent: Equatable {
  let title: String
  let message: String
  let buttonTitle: String

  static func localized(
    language: AppLanguage = .selected,
    bundle: Bundle = .main
  ) -> UpdateInstallationAlertContent {
    UpdateInstallationAlertContent(
      title: AppLocalization.string(
        "CodexRadar cannot install updates from its current location.",
        language: language,
        bundle: bundle
      ),
      message: AppLocalization.string(
        "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates.",
        language: language,
        bundle: bundle
      ),
      buttonTitle: AppLocalization.string("OK", language: language, bundle: bundle)
    )
  }
}

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, UpdaterStateChangeNotifying,
  SPUUpdaterDelegate
{
  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "updates"
  )

  let isAvailable = true
  let unavailableReasonKey: String? = nil
  var updaterStateDidChange: (@MainActor () -> Void)?

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
  private var canCheckForUpdatesObservation: NSKeyValueObservation?
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
    canCheckForUpdatesObservation = standardUpdaterController.updater.observe(
      \.canCheckForUpdates,
      options: [.new]
    ) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.updaterStateDidChange?()
      }
    }
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

    let content = UpdateInstallationAlertContent.localized()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = content.title
    alert.informativeText = content.message
    alert.addButton(withTitle: content.buttonTitle)
    alert.runModal()
  }
}
