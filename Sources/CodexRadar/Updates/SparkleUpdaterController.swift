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

enum UpdateReminderPolicy {
  static func shouldPost(userInitiated: Bool) -> Bool {
    !userInitiated
  }
}

struct UpdateReminderLifecycle {
  struct Session: Equatable {
    fileprivate let id = UUID()
  }

  private var activeSession: Session?

  mutating func beginSession() -> Session {
    let session = Session()
    activeSession = session
    return session
  }

  mutating func finishSession() {
    activeSession = nil
  }

  func shouldClearAfterPost(for session: Session) -> Bool {
    activeSession != session
  }
}

@MainActor
final class UpdateReminderCoordinator {
  typealias PostReminder = @MainActor (String) async -> Void
  typealias ClearReminder = @MainActor () -> Void

  private let postReminder: PostReminder
  private let clearReminder: ClearReminder
  private var lifecycle = UpdateReminderLifecycle()
  private var postTask: Task<Void, Never>?

  init(
    postReminder: @escaping PostReminder,
    clearReminder: @escaping ClearReminder
  ) {
    self.postReminder = postReminder
    self.clearReminder = clearReminder
  }

  @discardableResult
  func schedulePost(displayVersion: String) -> Task<Void, Never> {
    let reminderSession = lifecycle.beginSession()
    let previousPostTask = postTask
    let task = Task { @MainActor [weak self] in
      await previousPostTask?.value
      guard let self else { return }

      await self.postReminder(displayVersion)
      guard self.lifecycle.shouldClearAfterPost(for: reminderSession) else {
        return
      }

      self.clearReminder()
    }
    postTask = task
    return task
  }

  func finishSession() {
    lifecycle.finishSession()
    clearReminder()
  }
}

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, UpdaterStateChangeNotifying,
  SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate
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
  private let updateReminderNotifications: UpdateReminderNotificationService
  private var isShowingInstallationAlert = false
  private var canCheckForUpdatesObservation: NSKeyValueObservation?
  private lazy var updateReminderCoordinator = UpdateReminderCoordinator(
    postReminder: { [weak self] displayVersion in
      await self?.updateReminderNotifications.post(displayVersion: displayVersion)
    },
    clearReminder: { [weak self] in
      self?.updateReminderNotifications.clear()
    }
  )
  private lazy var standardUpdaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: self,
    userDriverDelegate: self
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
    },
    updateReminderNotifications: UpdateReminderNotificationService =
      UpdateReminderNotificationService()
  ) {
    self.bundleURL = bundleURL
    self.homeURL = homeURL
    self.isWritable = isWritable
    self.updateReminderNotifications = updateReminderNotifications
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

  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    true
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard UpdateReminderPolicy.shouldPost(userInitiated: state.userInitiated) else {
      return
    }

    let displayVersion = update.displayVersionString
    updateReminderCoordinator.schedulePost(displayVersion: displayVersion)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    updateReminderCoordinator.finishSession()
  }

  func standardUserDriverWillFinishUpdateSession() {
    updateReminderCoordinator.finishSession()
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
