import Foundation
@preconcurrency import UserNotifications

enum ResetNotificationDecision: Equatable {
  case establishBaseline(String?)
  case ignore
  case notify(String)
}

enum ResetNotificationPolicy {
  static func decision(
    forecast: ResetForecast,
    hasBaseline: Bool,
    consumedSignalIDs: Set<String>
  ) -> ResetNotificationDecision {
    guard hasBaseline else {
      return .establishBaseline(forecast.signalID)
    }
    guard !forecast.stale,
      [.candidate, .announced, .completed].contains(forecast.status),
      let signalID = forecast.signalID,
      !consumedSignalIDs.contains(signalID)
    else {
      return .ignore
    }
    return .notify(signalID)
  }
}

struct ResetNotificationPresentation: Equatable {
  enum Body: Equatable {
    case candidate
    case exact(Date)
    case estimated(Date, Date)
    case imminent
    case completed
  }

  let body: Body

  init?(forecast: ResetForecast) {
    guard !forecast.stale else { return nil }

    switch forecast.status {
    case .candidate:
      body = .candidate
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
    case .monitoring:
      return nil
    }
  }
}

@MainActor
final class ResetNotificationService {
  typealias DeliverNotification = @MainActor (ResetForecast, String) async -> Bool

  private let center: UNUserNotificationCenter?
  private let consumedSignalStore: ConsumedResetSignalStore
  private let deliverNotification: DeliverNotification

  init(
    center: UNUserNotificationCenter = .current(),
    defaults: UserDefaults = .standard,
    consumedSignalStore: ConsumedResetSignalStore? = nil,
    deliverNotification: DeliverNotification? = nil
  ) {
    self.center = center
    self.consumedSignalStore = consumedSignalStore ?? ConsumedResetSignalStore(defaults: defaults)
    self.deliverNotification = deliverNotification ?? { forecast, signalID in
      await Self.sendNotification(
        for: forecast,
        signalID: signalID,
        center: center
      )
    }
  }

  init(
    defaults: UserDefaults,
    consumedSignalStore: ConsumedResetSignalStore? = nil,
    deliverNotification: @escaping DeliverNotification
  ) {
    center = nil
    self.consumedSignalStore = consumedSignalStore ?? ConsumedResetSignalStore(defaults: defaults)
    self.deliverNotification = deliverNotification
  }

  func prepare() async {
    guard let center else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  func observe(_ forecast: ResetForecast) async {
    let decision = ResetNotificationPolicy.decision(
      forecast: forecast,
      hasBaseline: consumedSignalStore.hasBaseline,
      consumedSignalIDs: consumedSignalStore.consumedSignalIDs
    )

    switch decision {
    case .establishBaseline(let signalID):
      consumedSignalStore.establishBaseline(signalID: signalID)
    case .ignore:
      return
    case .notify(let signalID):
      guard await deliverNotification(forecast, signalID) else { return }
      consumedSignalStore.consume(signalID)
    }
  }

  private static func sendNotification(
    for forecast: ResetForecast,
    signalID: String,
    center: UNUserNotificationCenter
  ) async -> Bool {
    guard let presentation = ResetNotificationPresentation(forecast: forecast) else {
      return false
    }
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized
      || settings.authorizationStatus == .provisional
    else {
      return false
    }

    let content = UNMutableNotificationContent()
    let locale = AppLanguage.selected.locale
    switch presentation.body {
    case .candidate:
      content.title = AppLocalization.string("Possible Codex reset detected")
      content.body = AppLocalization.string("A possible Codex reset signal was posted.")
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
    do {
      try await center.add(request)
      return true
    } catch {
      return false
    }
  }
}
