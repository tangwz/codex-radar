import AppKit
import SwiftUI

enum MenuActionID: String, CaseIterable, Hashable {
  case refresh
  case dashboard
  case settings
  case about
  case quit

  static let applicationActions = MenuActionID.allCases
}

@MainActor
struct MenuRefreshAction {
  let refreshDashboard: () async -> Void
  let refreshHistory: () -> Void

  func perform() async {
    refreshHistory()
    await refreshDashboard()
  }
}

struct MenuBarPanelRootView: View {
  @ObservedObject var store: DashboardStore
  let historyStore: ResetHistoryStore
  let actions: MenuBarPanelActions
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  private var selectedLocale: Locale {
    AppLanguage(rawValue: language)?.locale ?? .current
  }

  private var preferredColorScheme: ColorScheme? {
    AppAppearance.resolve(appearance).colorScheme
  }

  var body: some View {
    MenuBarView(
      store: store,
      historyStore: historyStore,
      actions: actions
    )
    .environment(\.locale, selectedLocale)
    .preferredColorScheme(preferredColorScheme)
  }
}

struct MenuBarView: View {
  @ObservedObject var store: DashboardStore
  let historyStore: ResetHistoryStore
  let actions: MenuBarPanelActions
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.timeZone) private var timeZone

  private var theme: MenuBarTheme {
    MenuBarTheme(colorScheme: colorScheme)
  }

  private var refreshAction: MenuRefreshAction {
    MenuRefreshAction(
      refreshDashboard: {
        await store.refresh()
      },
      refreshHistory: {
        historyStore.refresh(timeZone: timeZone)
      }
    )
  }

  private var todayTokens: Int {
    store.tokenUsageSnapshot?.metrics(for: .day).totalTokens ?? 0
  }

  private var monthTokens: Int {
    store.tokenUsageSnapshot?.metrics(for: .month).totalTokens ?? 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MenuResetPredictionCard(
        forecast: store.forecast,
        isRefreshing: store.isRefreshing,
        isInitialForecastLoad: store.isInitialForecastLoad,
        theme: theme,
        openSource: actions.openSource
      )

      HStack(spacing: 10) {
        MenuMetric(title: "Today", value: todayTokens, theme: theme)
        MenuMetric(title: "This month", value: monthTokens, theme: theme)
      }

      Divider()
        .overlay(theme.isDarkRedesign ? theme.darkHairline : .clear)

      VStack(alignment: .leading, spacing: theme.actionPresentation == .insetGroup ? 0 : 2) {
        ForEach(MenuActionID.applicationActions, id: \.self) { action in
          actionControl(action)
          if theme.actionPresentation == .insetGroup, action != .quit {
            Rectangle()
              .fill(theme.darkHairline)
              .frame(height: 1)
              .padding(.leading, 36)
          }
        }
      }
      .padding(.vertical, theme.actionPresentation == .insetGroup ? 4 : 0)
      .background {
        if theme.actionPresentation == .insetGroup {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.insetSurface)
            .overlay {
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.darkHairline, lineWidth: 1)
            }
        }
      }
    }
    .padding(16)
    .frame(width: 300)
    .background(theme.isDarkRedesign ? theme.panelBackground : .clear)
    .task {
      store.startMonitoring()
    }
    .onChange(of: timeZone.identifier) {
      Task {
        await store.refreshTokenUsage(timeZone: timeZone)
      }
    }
  }

  @ViewBuilder
  private func actionControl(_ action: MenuActionID) -> some View {
    switch action {
    case .refresh:
      Button {
        Task { await refreshAction.perform() }
      } label: {
        MenuActionRow(
          title: "Refresh",
          systemImage: "arrow.clockwise",
          shortcut: "⌘R",
          isLoading: store.isRefreshing,
          theme: theme
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut("r", modifiers: .command)
      .disabled(store.isRefreshing)

    case .dashboard:
      Button {
        actions.openSettings(.dashboard)
      } label: {
        MenuActionRow(
          title: "Dashboard",
          systemImage: "rectangle.grid.2x2",
          shortcut: "⌘D",
          theme: theme
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut("d", modifiers: .command)

    case .settings:
      Button {
        actions.openSettings(.settings)
      } label: {
        MenuActionRow(
          title: "Settings",
          systemImage: "gearshape",
          shortcut: "⌘,",
          theme: theme
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut(",", modifiers: .command)

    case .about:
      Button {
        actions.openSettings(.about)
      } label: {
        MenuActionRow(
          title: "About",
          systemImage: "info.circle",
          theme: theme
        )
      }
      .buttonStyle(.plain)

    case .quit:
      Button {
        actions.quit()
      } label: {
        MenuActionRow(title: "Quit", systemImage: "power", shortcut: "⌘Q", theme: theme)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("q", modifiers: .command)
    }
  }
}

private struct MenuResetPredictionCard: View {
  let forecast: ResetForecast
  let isRefreshing: Bool
  let isInitialForecastLoad: Bool
  let theme: MenuBarTheme
  let openSource: (URL) -> Void
  @Environment(\.locale) private var locale

  private var presentation: ResetForecastPresentation {
    ResetForecastPresentation(forecast: forecast)
  }

  private var primaryText: Color {
    theme.isDarkRedesign ? theme.darkPrimaryText : Color(nsColor: .labelColor)
  }

  private var secondaryText: Color {
    theme.isDarkRedesign ? theme.darkSecondaryText : Color(nsColor: .secondaryLabelColor)
  }

  private var cardBackground: LinearGradient {
    let colors =
      theme.isDarkRedesign
      ? [theme.cobaltStart, theme.cobaltEnd]
      : [Color.accentColor.opacity(0.07), Color.accentColor.opacity(0.07)]

    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private var borderColor: Color {
    if presentation.stale {
      return Color.orange.opacity(0.55)
    }
    if presentation.status == .announced {
      return Color.red.opacity(0.5)
    }
    if presentation.status == .completed {
      return Color.green.opacity(0.5)
    }

    return theme.isDarkRedesign ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.35)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 10) {
        RadarLogo(hasAlert: presentation.hasResetAlert, theme: theme)

        VStack(alignment: .leading, spacing: 3) {
          Text("Next reset forecast")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .layoutPriority(1)

          if case .exact(let at) = presentation.timeDisplay {
            Text(
              at,
              format: .dateTime
                .month(.abbreviated)
                .day()
                .weekday(.abbreviated)
                .locale(locale)
            )
            .font(.caption)
            .foregroundStyle(secondaryText)
          }
        }

        Spacer(minLength: 4)

        if isRefreshing {
          ProgressView()
            .controlSize(.small)
            .frame(minHeight: 22)
        } else {
          ResetStatusBadge(presentation: presentation, theme: theme)
        }
      }

      timeContent

      recentResetContent

      if let sourceURL = presentation.sourceURL {
        Button {
          openSource(sourceURL)
        } label: {
          PredictionSourceChip(theme: theme)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(12)
    .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(borderColor, lineWidth: 1)
    }
    .shadow(
      color: theme.isDarkRedesign ? Color.black.opacity(0.35) : .clear,
      radius: 10,
      y: 5
    )
  }

  @ViewBuilder
  private var timeContent: some View {
    switch presentation.timeDisplay {
    case .exact(let at):
      TimelineView(.periodic(from: .now, by: 60)) { context in
        HStack(alignment: .lastTextBaseline, spacing: 8) {
          Text(at, format: .dateTime.hour().minute().locale(locale))
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .foregroundStyle(primaryText)
            .monospacedDigit()
            .lineLimit(1)

          Spacer(minLength: 2)

          Text(
            String(
              format: String(localized: "In %@", bundle: .main, locale: locale),
              DisplayFormatting.countdown(to: at, from: context.date, locale: locale)
            )
          )
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(theme.isDarkRedesign ? Color.white : Color.accentColor)
          .lineLimit(1)
          .padding(.horizontal, 7)
          .padding(.vertical, 5)
          .background(
            theme.isDarkRedesign ? Color.white.opacity(0.14) : Color.accentColor.opacity(0.1),
            in: Capsule()
          )
        }
      }
    case .estimated(let from, let to):
      VStack(alignment: .leading, spacing: 3) {
        Text("Estimated reset window")
          .font(.title3.weight(.semibold))
          .foregroundStyle(primaryText)
        Text(
          String(
            format: String(localized: "Between %@ and %@", bundle: .main, locale: locale),
            DisplayFormatting.absoluteDate(from, locale: locale),
            DisplayFormatting.absoluteDate(to, locale: locale)
          )
        )
        .font(.caption)
        .foregroundStyle(secondaryText)
      }
    case .imminent:
      VStack(alignment: .leading, spacing: 3) {
        Text("Reset expected soon")
          .font(.title3.weight(.semibold))
          .foregroundStyle(primaryText)
        Text("No precise reset time is available")
          .font(.caption)
          .foregroundStyle(secondaryText)
      }
    case .none:
      Text(LocalizedStringKey(emptyStateTitleKey))
        .font(.title3.weight(.semibold))
        .foregroundStyle(primaryText)
    }
  }

  @ViewBuilder
  private var recentResetContent: some View {
    let text = presentation.recentResetText(
      isInitialLoad: isInitialForecastLoad,
      locale: locale
    )

    Text(text)
      .font(.caption.weight(.medium))
      .foregroundStyle(secondaryText)
      .accessibilityLabel(Text("Last reset"))
      .accessibilityValue(Text(text))
  }

  private var emptyStateTitleKey: String {
    if presentation.stale { return "Source unavailable" }
    return switch presentation.status {
    case .monitoring: "No reset signal"
    case .candidate: "Possible reset signal"
    case .announced: "Reset announced"
    case .completed: "Ready to use"
    }
  }

}

private struct RadarLogo: View {
  let hasAlert: Bool
  let theme: MenuBarTheme

  private var radarColor: Color {
    theme.isDarkRedesign ? Color(red: 0.28, green: 0.67, blue: 1.0) : Color.accentColor
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(radarColor.opacity(theme.isDarkRedesign ? 0.24 : 0.16))

      ForEach([0.38, 0.62, 0.84], id: \.self) { scale in
        Circle()
          .stroke(radarColor.opacity(0.9), lineWidth: 1.4)
          .scaleEffect(scale)
      }

      Capsule()
        .fill(radarColor)
        .frame(width: 25, height: 2)
        .offset(x: 8)
        .rotationEffect(.degrees(-45))

      Circle()
        .fill(radarColor)
        .frame(width: 7, height: 7)
    }
    .frame(width: 46, height: 46)
    .overlay(alignment: .topTrailing) {
      if hasAlert {
        Circle()
          .fill(.red)
          .frame(width: 8, height: 8)
          .overlay(Circle().stroke(.background, lineWidth: 1.5))
      }
    }
    .accessibilityHidden(true)
  }
}

private struct ResetStatusBadge: View {
  let presentation: ResetForecastPresentation
  let theme: MenuBarTheme

  private var titleKey: String {
    if presentation.stale { return "Source unavailable" }
    return switch presentation.status {
    case .monitoring: "Monitoring"
    case .candidate: "Watching"
    case .announced: "Reset announced"
    case .completed: "Reset completed"
    }
  }

  private var color: Color {
    if presentation.stale { return .orange }
    return switch presentation.status {
    case .monitoring: theme.isDarkRedesign ? .white : .accentColor
    case .candidate: .yellow
    case .announced: .red
    case .completed: .green
    }
  }

  var body: some View {
    Text(LocalizedStringKey(titleKey))
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(
        color.opacity(theme.isDarkRedesign ? 0.14 : 0.1),
        in: Capsule()
      )
  }
}

private struct PredictionSourceChip: View {
  let theme: MenuBarTheme
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      Text("X")
        .font(.caption.weight(.bold))
      Text("Source: Tibo on X")
        .font(.caption)
        .lineLimit(1)
      Image(systemName: "arrow.up.right")
        .font(.caption2.weight(.semibold))
    }
    .foregroundStyle(
      theme.isDarkRedesign ? theme.darkSecondaryText : Color(nsColor: .secondaryLabelColor)
    )
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .background(
      theme.isDarkRedesign
        ? Color.white.opacity(isHovered ? 0.18 : 0.1)
        : (isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
  }
}

enum MenuBarIconConfiguration {
  static let sideLength: CGFloat = 18

  private static let strokeWidth: CGFloat = 1.5
  private static let center = NSPoint(x: 9, y: 9)

  @MainActor
  static let image: NSImage = {
    let size = NSSize(width: sideLength, height: sideLength)
    let image = NSImage(size: size, flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()

      let ringFrames = [
        NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5),
        NSRect(x: 5, y: 5, width: 8, height: 8),
      ]
      for frame in ringFrames {
        let ring = NSBezierPath(ovalIn: frame)
        ring.lineWidth = strokeWidth
        ring.stroke()
      }

      let sweep = NSBezierPath()
      sweep.lineWidth = strokeWidth
      sweep.lineCapStyle = .round
      sweep.move(to: center)
      sweep.line(to: NSPoint(x: 13.8, y: 14.1))
      sweep.stroke()

      NSBezierPath(
        ovalIn: NSRect(x: 8, y: 8, width: 2, height: 2)
      ).fill()
      return true
    }
    image.isTemplate = true
    return image
  }()
}

private struct MenuMetric: View {
  let title: LocalizedStringKey
  let value: Int
  let theme: MenuBarTheme
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(
          theme.isDarkRedesign ? theme.darkSecondaryText : Color(nsColor: .secondaryLabelColor)
        )
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .font(.title3.weight(.semibold))
        .foregroundStyle(
          theme.isDarkRedesign ? theme.darkPrimaryText : Color(nsColor: .labelColor)
        )
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background {
      if theme.isDarkRedesign {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(theme.elevatedSurface)
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.quaternary.opacity(0.35))
      }
    }
    .overlay {
      if theme.isDarkRedesign {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.darkHairline, lineWidth: 1)
      }
    }
  }
}

private struct MenuActionRow: View {
  let title: LocalizedStringKey
  let systemImage: String
  var shortcut: String?
  var isLoading = false
  let theme: MenuBarTheme
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 18)

      Text(title)
        .lineLimit(1)

      Spacer(minLength: 12)

      if isLoading {
        ProgressView()
          .controlSize(.small)
      } else if let shortcut {
        if theme.isDarkRedesign {
          Text(shortcut)
            .foregroundStyle(theme.darkTertiaryText)
        } else {
          Text(shortcut)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .foregroundStyle(
      theme.isDarkRedesign ? theme.darkPrimaryText : Color(nsColor: .labelColor)
    )
    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .background(
      isHovered
        ? (theme.isDarkRedesign ? Color.white.opacity(0.07) : Color.primary.opacity(0.08))
        : .clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
  }
}
