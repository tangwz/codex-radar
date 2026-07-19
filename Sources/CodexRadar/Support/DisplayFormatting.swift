import Foundation

enum DisplayFormatting {
  static func tokenCount(_ value: Int, locale: Locale = .current) -> String {
    value.formatted(.number.notation(.compactName).locale(locale))
  }

  static func absoluteDate(
    _ date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
    )
  }

  static func bucketDate(
    _ date: Date,
    period: TokenUsagePeriod,
    locale: Locale = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    switch period {
    case .day: formatter.setLocalizedDateFormatFromTemplate("MMM d")
    case .month: formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
    case .year: formatter.setLocalizedDateFormatFromTemplate("yyyy")
    }
    return formatter.string(from: date)
  }

  static func countdown(to target: Date, from now: Date, locale: Locale = .current) -> String {
    let totalMinutes = max(0, Int(target.timeIntervalSince(now)) / 60)
    let days = totalMinutes / (24 * 60)
    let hours = totalMinutes / 60 % 24
    let minutes = totalMinutes % 60

    if locale.language.languageCode?.identifier == "zh" {
      if days > 0 {
        return "\(days)\u{5929} \(hours)\u{5C0F}\u{65F6} \(minutes)\u{5206}\u{949F}"
      }
      return "\(hours)\u{5C0F}\u{65F6} \(minutes)\u{5206}\u{949F}"
    }
    if days > 0 {
      return "\(days)d \(hours)h \(minutes)m"
    }
    return "\(hours)h \(minutes)m"
  }
}
