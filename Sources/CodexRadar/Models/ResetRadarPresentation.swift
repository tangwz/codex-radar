import Foundation

struct ResetRadarPresentation: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case inactive
    case hard
    case banked
    case hardAndBanked
  }

  enum EndMarker: Equatable, Sendable {
    case today
    case latest
  }

  struct Day: Equatable, Identifiable, Sendable {
    let id: String
    let date: Date
    let dateLabel: String
    let kind: Kind
    let isToday: Bool
  }

  let days: [Day]
  let activeDayCount: Int
  let startLabel: String
  let endLabel: String
  let endMarker: EndMarker

  init?(
    history: ResetHistory,
    locale: Locale,
    now: Date = Date()
  ) {
    guard let radarDays = history.radarDays else { return nil }
    guard let timeZone = TimeZone(identifier: history.timeZone) else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let fullDateStyle = Date.FormatStyle(
      date: .long,
      time: .omitted,
      locale: locale,
      timeZone: timeZone
    )
    let shortDateStyle = Date.FormatStyle(
      date: .omitted,
      time: .omitted,
      locale: locale,
      timeZone: timeZone
    )
    .month(.abbreviated)
    .day()

    var mappedDays: [Day] = []
    mappedDays.reserveCapacity(radarDays.count)
    for (index, day) in radarDays.enumerated() {
      guard let kind = Self.kind(for: day.counts) else { return nil }
      let isLast = index == radarDays.index(before: radarDays.endIndex)
      mappedDays.append(
        Day(
          id: day.id,
          date: day.from,
          dateLabel: day.from.formatted(fullDateStyle),
          kind: kind,
          isToday: isLast && calendar.isDate(day.from, inSameDayAs: now)
        )
      )
    }
    guard let first = mappedDays.first, let last = mappedDays.last else { return nil }

    days = mappedDays
    activeDayCount = mappedDays.count { $0.kind != .inactive }
    startLabel = first.date.formatted(shortDateStyle)
    endLabel = last.date.formatted(shortDateStyle)
    endMarker = last.isToday ? .today : .latest
  }

  private static func kind(for counts: ResetCounts) -> Kind? {
    switch (counts.hard, counts.banked, counts.both) {
    case (0, 0, 0): .inactive
    case (let hard, 0, 0) where hard > 0: .hard
    case (0, let banked, 0) where banked > 0: .banked
    case (let hard, let banked, let both)
    where hard > 0 && hard == banked && banked == both: .hardAndBanked
    default: nil
    }
  }
}
