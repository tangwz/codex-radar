import Foundation
import UserNotifications

enum ResetNotificationPolicy {
  static func shouldNotify(forecast: ResetForecast, lastSourceURL: String?) -> Bool {
    forecast.isActive && forecast.sourceURL.absoluteString != lastSourceURL
  }
}

@MainActor
final class ResetNotificationService {
  private let center = UNUserNotificationCenter.current()
  private let defaults = UserDefaults.standard
  private let lastSourceKey = "lastNotifiedResetSourceURL"

  func prepare() async {
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  func notifyIfNeeded(for forecast: ResetForecast) async {
    let lastSourceURL = defaults.string(forKey: lastSourceKey)
    guard
      ResetNotificationPolicy.shouldNotify(
        forecast: forecast,
        lastSourceURL: lastSourceURL
      )
    else {
      return
    }

    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
    else {
      return
    }

    let content = UNMutableNotificationContent()
    let locale = AppLanguage.selected.locale
    content.title = AppLocalization.string("Codex reset window is open")
    content.body =
      forecast.predictedAt.map {
        String(
          format: AppLocalization.string("A reset is expected by %@."),
          DisplayFormatting.absoluteDate($0, locale: locale)
        )
      } ?? AppLocalization.string("A new official Codex reset signal was detected.")
    content.sound = .default
    content.threadIdentifier = "codex-reset"

    let request = UNNotificationRequest(
      identifier: "codex-reset-\(forecast.announcedAt.timeIntervalSince1970)",
      content: content,
      trigger: nil
    )

    do {
      try await center.add(request)
      defaults.set(forecast.sourceURL.absoluteString, forKey: lastSourceKey)
    } catch {
      return
    }
  }
}
