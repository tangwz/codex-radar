import Foundation

struct ResetHistoryPresentation {
  struct Month: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
  }

  struct Recent: Identifiable, Equatable {
    let id: String
    let dateTime: String
  }

  let year: Int
  let availableYears: [Int]
  let weekCount: Int
  let monthCount: Int
  let months: [Month]
  let recent: [Recent]

  init(history: ResetHistory, locale: Locale) {
    let timeZone = TimeZone(identifier: history.timeZone)!

    year = history.year
    availableYears = Set(history.availableYears + [history.year]).sorted(by: >)
    weekCount = history.current.week.count
    monthCount = history.current.month.count
    months = history.months.map { summary in
      Month(
        id: summary.id,
        label: summary.from.formatted(
          Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            timeZone: timeZone
          )
          .month(.abbreviated)
        ),
        count: summary.count
      )
    }
    recent = history.recent.map { event in
      Recent(
        id: event.id,
        dateTime: DisplayFormatting.absoluteDate(
          event.resetAt,
          locale: locale,
          timeZone: timeZone
        )
      )
    }
  }
}
