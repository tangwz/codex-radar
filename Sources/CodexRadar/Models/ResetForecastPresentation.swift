import Foundation

struct ResetForecastPresentation: Equatable {
  enum TimeDisplay: Equatable {
    case none
    case exact(Date)
    case estimated(Date, Date)
    case imminent
  }

  enum LastResetDisplay: Equatable {
    case unavailable
    case none
    case resetAt(Date)
  }

  let status: ResetStatus
  let action: RecommendedAction
  let stale: Bool
  let timeDisplay: TimeDisplay
  let lastResetDisplay: LastResetDisplay
  let sourceURL: URL?

  init(forecast: ResetForecast) {
    status = forecast.status
    action = forecast.stale ? .unknown : forecast.recommendedAction
    stale = forecast.stale
    sourceURL = forecast.sourceURL
    lastResetDisplay =
      switch forecast.lastReset {
      case .unavailable: .unavailable
      case .none: .none
      case .resetAt(let value): .resetAt(value)
      }

    guard !forecast.stale, forecast.status == .announced else {
      timeDisplay = .none
      return
    }
    switch forecast.timing?.kind {
    case .exact:
      timeDisplay = forecast.timing?.at.map(TimeDisplay.exact) ?? .none
    case .estimated:
      if let from = forecast.timing?.from, let to = forecast.timing?.to {
        timeDisplay = .estimated(from, to)
      } else {
        timeDisplay = .none
      }
    case .imminent, nil:
      timeDisplay = .imminent
    }
  }

  var hasResetAlert: Bool {
    !stale && status == .announced
  }

  func recentResetText(
    isInitialLoad: Bool,
    locale: Locale,
    bundle: Bundle = .main
  ) -> String {
    switch lastResetDisplay {
    case .resetAt(let value):
      DisplayFormatting.absoluteDate(value, locale: locale)
    case .none:
      String(localized: "No reset history", bundle: bundle, locale: locale)
    case .unavailable where isInitialLoad:
      String(localized: "Fetching reset time", bundle: bundle, locale: locale)
    case .unavailable:
      String(localized: "Reset time unavailable", bundle: bundle, locale: locale)
    }
  }
}
