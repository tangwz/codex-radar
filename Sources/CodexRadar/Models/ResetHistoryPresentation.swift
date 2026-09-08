import Foundation

enum ResetHistoryMetric: String, CaseIterable, Identifiable {
  case both
  case hard
  case banked

  var id: Self { self }
}

extension ResetCounts {
  func count(for metric: ResetHistoryMetric) -> Int {
    switch metric {
    case .both: both
    case .hard: hard
    case .banked: banked
    }
  }
}

struct ResetHistoryPresentation {
  struct Month: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
  }

  let selectedRange: ResetHistoryRange
  let metric: ResetHistoryMetric
  let rangeDescription: String
  let weekCount: Int
  let monthCount: Int
  let months: [Month]

  init(
    history: ResetHistory,
    selectedRange: ResetHistoryRange,
    metric: ResetHistoryMetric,
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
      ? Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
        .month(.abbreviated).year(.twoDigits)
      : Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
        .month(.abbreviated)
    let rangeStyle = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale, timeZone: timeZone
    ).month(.abbreviated).year()

    // The public API has mutually exclusive regular/banked records. Its first
    // metric is their total, NOT the old backend's simultaneous-reset subset.
    func count(_ counts: ResetCounts) -> Int {
      if history.usesPublicAnnouncements, metric == .both {
        return counts.hard + counts.banked
      }
      return counts.count(for: metric)
    }
    self.selectedRange = selectedRange
    self.metric = metric
    rangeDescription = [visibleSummaries.first, visibleSummaries.last]
      .compactMap { $0?.from.formatted(rangeStyle) }
      .joined(separator: " – ")
    weekCount = count(history.current.week.counts)
    monthCount = count(history.current.month.counts)
    months = visibleSummaries.map { summary in
      Month(id: summary.id, label: summary.from.formatted(monthStyle), count: count(summary.counts))
    }
  }
}
