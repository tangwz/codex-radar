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

  let selectedRange: ResetHistoryRange
  let responseRevision: Date
  let rangeDescription: String
  let weekCount: Int
  let monthCount: Int
  let months: [Month]
  let recent: [Recent]

  init(
    history: ResetHistory,
    selectedRange: ResetHistoryRange,
    locale: Locale
  ) {
    let timeZone = TimeZone(identifier: history.timeZone)!
    let visibleSummaries: ArraySlice<ResetMonthSummary>
    if let count = selectedRange.fixedMonthCount {
      visibleSummaries = history.months.suffix(count)
    } else {
      visibleSummaries = history.months[...]
    }
    let monthStyle =
      selectedRange == .all
      ? Date.FormatStyle(
        date: .omitted,
        time: .omitted,
        locale: locale,
        timeZone: timeZone
      ).month(.abbreviated).year(.twoDigits)
      : Date.FormatStyle(
        date: .omitted,
        time: .omitted,
        locale: locale,
        timeZone: timeZone
      ).month(.abbreviated)
    let rangeStyle = Date.FormatStyle(
      date: .omitted,
      time: .omitted,
      locale: locale,
      timeZone: timeZone
    ).month(.abbreviated).year()

    self.selectedRange = selectedRange
    responseRevision = history.generatedAt
    rangeDescription = [visibleSummaries.first, visibleSummaries.last]
      .compactMap { $0?.from.formatted(rangeStyle) }
      .joined(separator: " – ")
    weekCount = history.current.week.count
    monthCount = history.current.month.count
    months = visibleSummaries.map { summary in
      Month(
        id: summary.id,
        label: summary.from.formatted(monthStyle),
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
