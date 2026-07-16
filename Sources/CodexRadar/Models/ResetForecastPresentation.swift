import Foundation

struct ResetForecastPresentation: Equatable {
  enum TimeDisplay: Equatable {
    case none
    case exact(Date)
    case estimated(Date, Date)
    case imminent
  }

  let status: ResetStatus
  let action: RecommendedAction
  let stale: Bool
  let timeDisplay: TimeDisplay
  let sourceURL: URL?

  init(forecast: ResetForecast) {
    status = forecast.status
    action = forecast.stale ? .unknown : forecast.recommendedAction
    stale = forecast.stale
    sourceURL = forecast.sourceURL

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
}
