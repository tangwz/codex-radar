import Foundation

struct ResetForecast: Equatable, Sendable {
  let isActive: Bool
  let predictedAt: Date?
  let announcedAt: Date
  let title: String
  let summary: String
  let sourceURL: URL

  static let placeholder = ResetForecast(
    isActive: false,
    predictedAt: nil,
    announcedAt: .distantPast,
    title: "Checking reset signals",
    summary: "Looking for the latest official reset announcement.",
    sourceURL: URL(string: "https://x.com/thsottiaux")!
  )

  func expired(at date: Date) -> ResetForecast {
    guard isActive, let predictedAt, predictedAt <= date else { return self }
    return ResetForecast(
      isActive: false,
      predictedAt: nil,
      announcedAt: announcedAt,
      title: "Awaiting the next signal",
      summary: "The last announced reset window has ended. Monitoring remains active.",
      sourceURL: sourceURL
    )
  }
}
