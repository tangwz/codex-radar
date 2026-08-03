import SwiftUI

struct ResetRadarView: View {
  let presentation: ResetRadarPresentation

  @Environment(\.locale) private var locale
  @State private var hoveredDayID: String?
  @FocusState private var focusedDayID: String?

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 20), spacing: 8),
    count: 15
  )

  private var selectedDayID: String? {
    hoveredDayID ?? focusedDayID
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(presentation.days) { day in
          dayCell(day)
        }
      }

      HStack {
        Text(presentation.startLabel)
        Spacer()
        Text(endMarkerLabel)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      legend
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Reset radar")
          .font(.headline)
        Text("Last 30 days")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text(activeDayCountLabel)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          Color.green.opacity(0.12),
          in: Capsule()
        )
    }
  }

  private func dayCell(_ day: ResetRadarPresentation.Day) -> some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(fillColor(for: day.kind))
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(
            day.isToday ? ResetRadarPalette.todayOutline : .clear,
            lineWidth: day.isToday ? 2 : 0
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(
            focusedDayID == day.id ? Color.accentColor : .clear,
            lineWidth: focusedDayID == day.id ? 2 : 0
          )
          .padding(3)
      }
      .overlay(alignment: .top) {
        if selectedDayID == day.id {
          tooltip(for: day)
            .offset(y: -42)
            .transition(.opacity)
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .focusable()
      .focused($focusedDayID, equals: day.id)
      .onHover { isHovered in
        if isHovered {
          hoveredDayID = day.id
        } else if hoveredDayID == day.id {
          hoveredDayID = nil
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(accessibilityLabel(for: day)))
      .zIndex(selectedDayID == day.id ? 1 : 0)
  }

  private func tooltip(for day: ResetRadarPresentation.Day) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(day.dateLabel)
        .foregroundStyle(.secondary)
      Text(kindLabel(for: day.kind))
        .fontWeight(.semibold)
    }
    .font(.caption)
    .fixedSize()
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    .allowsHitTesting(false)
  }

  private var legend: some View {
    HStack(spacing: 16) {
      legendItem("Hard reset", color: ResetRadarPalette.hard)
      legendItem("Banked reset", color: ResetRadarPalette.banked)
      legendItem("Hard + banked", color: ResetRadarPalette.hardAndBanked)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func legendItem(_ title: LocalizedStringKey, color: Color) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(color)
        .frame(width: 12, height: 12)
      Text(title)
    }
  }

  private var activeDayCountLabel: String {
    String(
      format: String(
        localized: "%lld active days",
        bundle: .main,
        locale: locale
      ),
      locale: locale,
      Int64(presentation.activeDayCount)
    )
  }

  private var endMarkerLabel: String {
    let format: String =
      switch presentation.endMarker {
      case .today:
        String(localized: "Today · %@", bundle: .main, locale: locale)
      case .latest:
        String(localized: "Latest · %@", bundle: .main, locale: locale)
      }
    return String(format: format, locale: locale, presentation.endLabel)
  }

  private func accessibilityLabel(for day: ResetRadarPresentation.Day) -> String {
    "\(day.dateLabel), \(kindLabel(for: day.kind))"
  }

  private func kindLabel(for kind: ResetRadarPresentation.Kind) -> String {
    switch kind {
    case .inactive:
      String(localized: "No reset", bundle: .main, locale: locale)
    case .hard:
      String(localized: "Hard reset", bundle: .main, locale: locale)
    case .banked:
      String(localized: "Banked reset", bundle: .main, locale: locale)
    case .hardAndBanked:
      String(localized: "Hard + banked", bundle: .main, locale: locale)
    }
  }

  private func fillColor(for kind: ResetRadarPresentation.Kind) -> Color {
    switch kind {
    case .inactive: ResetRadarPalette.inactive
    case .hard: ResetRadarPalette.hard
    case .banked: ResetRadarPalette.banked
    case .hardAndBanked: ResetRadarPalette.hardAndBanked
    }
  }
}

struct ResetRadarUnavailableView: View {
  var body: some View {
    Label("Reset radar unavailable", systemImage: "square.grid.3x3.square")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
  }
}

private enum ResetRadarPalette {
  static let inactive = Color.secondary.opacity(0.12)
  static let hard = Color.green.opacity(0.48)
  static let banked = Color.green.opacity(0.70)
  static let hardAndBanked = Color.green.opacity(0.92)
  static let todayOutline = Color.primary.opacity(0.70)
}
