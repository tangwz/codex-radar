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

struct MenuBarView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var settingsSelection: SettingsSelection
  @Environment(\.openSettings) private var openSettings
  @Environment(\.colorScheme) private var colorScheme

  private var theme: MenuBarTheme {
    MenuBarTheme(colorScheme: colorScheme)
  }

  private var todayTokens: Int {
    TokenUsageAggregator.total(store.tokenEvents, in: .day)
  }

  private var monthTokens: Int {
    TokenUsageAggregator.total(store.tokenEvents, in: .month)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MenuResetPredictionCard(
        forecast: store.forecast,
        isRefreshing: store.isRefreshing,
        theme: theme
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
  }

  @ViewBuilder
  private func actionControl(_ action: MenuActionID) -> some View {
    switch action {
    case .refresh:
      Button {
        Task { await store.refresh() }
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
        showSettings(.dashboard)
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
        showSettings(.settings)
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
        showSettings(.about)
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
        NSApplication.shared.terminate(nil)
      } label: {
        MenuActionRow(title: "Quit", systemImage: "power", shortcut: "⌘Q", theme: theme)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("q", modifiers: .command)
    }
  }

  private func showSettings(_ pane: SettingsPane) {
    settingsSelection.show(pane)
    openSettings()
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct MenuResetPredictionCard: View {
  let forecast: ResetForecast
  let isRefreshing: Bool
  let theme: MenuBarTheme
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
    let colors = theme.isDarkRedesign
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

      if let sourceURL = presentation.sourceURL {
        Link(destination: sourceURL) {
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
      VStack(alignment: .leading, spacing: 3) {
        Text(LocalizedStringKey(emptyStateTitleKey))
          .font(.title3.weight(.semibold))
          .foregroundStyle(primaryText)
        Text(LocalizedStringKey(emptyStateDetailKey))
          .font(.caption)
          .foregroundStyle(secondaryText)
      }
    }
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

  private var emptyStateDetailKey: String {
    if presentation.stale { return "Showing the last verified reset state" }
    return switch presentation.status {
    case .monitoring: "Waiting for Tibo's next reset signal"
    case .candidate: "Watching for a confirmed reset announcement"
    case .announced: "A reset is expected soon"
    case .completed: "The announced reset has completed"
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
  static let assetName = "MenuBarIcon"
  static let sideLength: CGFloat = 18
  static let contentInset: CGFloat = 0

  static let image: NSImage = {
    let resourceURL = Bundle.main.url(forResource: assetName, withExtension: "png")
      ?? Bundle.module.url(forResource: assetName, withExtension: "png")

    let image = resourceURL.flatMap(NSImage.init(contentsOf:))
      ?? NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
      ?? NSImage(size: NSSize(width: sideLength, height: sideLength))
    image.size = NSSize(width: sideLength, height: sideLength)
    return image
  }()
}

struct MenuBarLabel: View {
  let hasResetAlert: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Image(nsImage: MenuBarIconConfiguration.image)
        .resizable()
        .renderingMode(.original)
        .interpolation(.high)
        .scaledToFit()
        .padding(MenuBarIconConfiguration.contentInset)
        .frame(
          width: MenuBarIconConfiguration.sideLength,
          height: MenuBarIconConfiguration.sideLength
        )
      if hasResetAlert {
        Circle()
          .fill(.red)
          .frame(width: 6, height: 6)
          .offset(x: 2, y: -2)
      }
    }
    .accessibilityLabel(
      hasResetAlert
        ? LocalizedStringKey("Codex reset incoming")
        : LocalizedStringKey("Codex reset monitoring"))
  }
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
