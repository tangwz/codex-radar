import Foundation
import UserNotifications

enum ResetNotificationDecision: Equatable {
  case establishBaseline(String?)
  case ignore
  case notify(String)
}

enum ResetNotificationPolicy {
  static func decision(
    forecast: ResetForecast,
    hasBaseline: Bool,
    lastSignalID: String?
  ) -> ResetNotificationDecision {
    guard hasBaseline else {
      return .establishBaseline(forecast.signalID)
    }
    guard !forecast.stale,
      forecast.status == .announced || forecast.status == .completed,
      let signalID = forecast.signalID,
      signalID != lastSignalID
    else {
      return .ignore
    }
    return .notify(signalID)
  }
}

struct ResetNotificationPresentation: Equatable {
  enum Body: Equatable {
    case exact(Date)
    case estimated(Date, Date)
    case imminent
    case completed
  }

  let body: Body

  init?(forecast: ResetForecast) {
    guard !forecast.stale else { return nil }

    switch forecast.status {
    case .completed:
      body = .completed
    case .announced:
      switch forecast.timing?.kind {
      case .exact:
        guard let at = forecast.timing?.at else { return nil }
        body = .exact(at)
      case .estimated:
        guard let from = forecast.timing?.from, let to = forecast.timing?.to else { return nil }
        body = .estimated(from, to)
      case .imminent, nil:
        body = .imminent
      }
    case .candidate, .monitoring:
      return nil
    }
  }
}

@MainActor
final class ResetNotificationService {
  private let center = UNUserNotificationCenter.current()
  private let defaults = UserDefaults.standard
  private let hasBaselineKey = "hasResetSignalBaseline"
  private let lastSignalIDKey = "lastObservedResetSignalID"

  func prepare() async {
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  func observe(_ forecast: ResetForecast) async {
    let decision = ResetNotificationPolicy.decision(
      forecast: forecast,
      hasBaseline: defaults.bool(forKey: hasBaselineKey),
      lastSignalID: defaults.string(forKey: lastSignalIDKey)
    )

    switch decision {
    case .establishBaseline(let signalID):
      persistBaseline(signalID)
    case .ignore:
      return
    case .notify(let signalID):
      persistBaseline(signalID)
      await sendNotification(for: forecast, signalID: signalID)
    }
  }

  private func persistBaseline(_ signalID: String?) {
    defaults.set(true, forKey: hasBaselineKey)
    if let signalID {
      defaults.set(signalID, forKey: lastSignalIDKey)
    } else {
      defaults.removeObject(forKey: lastSignalIDKey)
    }
  }

  private func sendNotification(for forecast: ResetForecast, signalID: String) async {
    guard let presentation = ResetNotificationPresentation(forecast: forecast) else { return }
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized
      || settings.authorizationStatus == .provisional
    else {
      return
    }

    let content = UNMutableNotificationContent()
    let locale = AppLanguage.selected.locale
    switch presentation.body {
    case .exact(let at):
      content.title = AppLocalization.string("Codex reset announced")
      content.body = String(
        format: AppLocalization.string("A reset is expected by %@."),
        DisplayFormatting.absoluteDate(at, locale: locale)
      )
    case .estimated(let from, let to):
      content.title = AppLocalization.string("Codex reset announced")
      content.body = String(
        format: AppLocalization.string("A reset is expected between %@ and %@."),
        DisplayFormatting.absoluteDate(from, locale: locale),
        DisplayFormatting.absoluteDate(to, locale: locale)
      )
    case .imminent:
      content.title = AppLocalization.string("Codex reset announced")
      content.body = AppLocalization.string("A Codex reset is expected soon.")
    case .completed:
      content.title = AppLocalization.string("Codex reset completed")
      content.body = AppLocalization.string("Codex is available to use now.")
    }
    content.sound = .default
    content.threadIdentifier = "codex-reset"

    let request = UNNotificationRequest(
      identifier: signalID,
      content: content,
      trigger: nil
    )
    try? await center.add(request)
  }
}
