import Foundation
import OSLog
@preconcurrency import UserNotifications

struct UpdateReminderNotificationPresentation: Equatable {
  let title: String
  let body: String

  static func localized(
    displayVersion: String,
    language: AppLanguage = .selected,
    bundle: Bundle = .main
  ) -> UpdateReminderNotificationPresentation {
    UpdateReminderNotificationPresentation(
      title: AppLocalization.string(
        "A new CodexRadar update is available",
        language: language,
        bundle: bundle
      ),
      body: String(
        format: AppLocalization.string(
          "Version %@ is now available.",
          language: language,
          bundle: bundle
        ),
        displayVersion
      )
    )
  }
}

enum UpdateReminderNotification {
  static let identifier = "codex-radar-update-available"

  static func isDefaultAction(
    identifier: String,
    actionIdentifier: String
  ) -> Bool {
    identifier == self.identifier
      && actionIdentifier == UNNotificationDefaultActionIdentifier
  }
}

@MainActor
final class UpdateReminderNotificationService {
  typealias AuthorizationStatusProvider = @MainActor () async -> UNAuthorizationStatus
  typealias AddRequest = @MainActor (UNNotificationRequest) async throws -> Void
  typealias RemoveRequests = @MainActor ([String]) -> Void

  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "updates"
  )

  private let authorizationStatus: AuthorizationStatusProvider
  private let addRequest: AddRequest
  private let removePending: RemoveRequests
  private let removeDelivered: RemoveRequests

  init(center: UNUserNotificationCenter = .current()) {
    authorizationStatus = {
      let settings = await center.notificationSettings()
      return settings.authorizationStatus
    }
    addRequest = { request in
      try await center.add(request)
    }
    removePending = { identifiers in
      center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    removeDelivered = { identifiers in
      center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
  }

  init(
    authorizationStatus: @escaping AuthorizationStatusProvider,
    addRequest: @escaping AddRequest,
    removePending: @escaping RemoveRequests,
    removeDelivered: @escaping RemoveRequests
  ) {
    self.authorizationStatus = authorizationStatus
    self.addRequest = addRequest
    self.removePending = removePending
    self.removeDelivered = removeDelivered
  }

  func post(
    displayVersion: String,
    language: AppLanguage = .selected,
    bundle: Bundle = .main
  ) async {
    let status = await authorizationStatus()
    guard status == .authorized || status == .provisional else { return }

    let presentation = UpdateReminderNotificationPresentation.localized(
      displayVersion: displayVersion,
      language: language,
      bundle: bundle
    )
    let content = UNMutableNotificationContent()
    content.title = presentation.title
    content.body = presentation.body
    content.sound = .default
    content.threadIdentifier = "codex-radar-update"

    clear()
    let request = UNNotificationRequest(
      identifier: UpdateReminderNotification.identifier,
      content: content,
      trigger: nil
    )
    do {
      try await addRequest(request)
    } catch {
      let error = error as NSError
      Self.logger.error(
        "Failed to post update reminder: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
      )
    }
  }

  func clear() {
    let identifiers = [UpdateReminderNotification.identifier]
    removePending(identifiers)
    removeDelivered(identifiers)
  }
}
