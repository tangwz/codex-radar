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
        MenuActionRow(title: "About", systemImage: "info.circle", theme: theme)
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

  private var detailKey: String {
    if forecast.stale { return "unavailable" }
    return forecast.status == .candidate ? "forecastDisclaimer"
      : forecast.status == .announced ? "announcementDisclaimer" : "waiting"
  }

  private var primaryText: Color {
    theme.isDarkRedesign ? theme.darkPrimaryText : Color(nsColor: .labelColor)
  }

  private var secondaryText: Color {
    theme.isDarkRedesign ? theme.darkSecondaryText : Color(nsColor: .secondaryLabelColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        Image(systemName: "scope")
          .font(.title2)
          .overlay(alignment: .topTrailing) {
            if presentation.hasResetAlert {
              Circle().fill(.red).frame(width: 6, height: 6)
            }
          }
        Text(CodexResetsCopy.text("title", locale: locale))
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.82)
        Spacer(minLength: 4)
        if isRefreshing {
          ProgressView().controlSize(.small)
        }
      }
      .foregroundStyle(primaryText)

      Text(CodexResetsCopy.text(detailKey, locale: locale))
        .font(.caption)
        .foregroundStyle(secondaryText)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 3) {
        Text(CodexResetsCopy.text("lastAnnouncement", locale: locale))
          .font(.caption2)
        Text(presentation.recentResetText(isInitialLoad: isInitialForecastLoad, locale: locale))
          .font(.caption.weight(.medium))
      }
      .foregroundStyle(secondaryText)

      if let sourceURL = presentation.sourceURL {
        Button {
          openSource(sourceURL)
        } label: {
          Label(CodexResetsCopy.text("source", locale: locale), systemImage: "arrow.up.right")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(primaryText)
      }
      Text(CodexResetsCopy.text("attribution", locale: locale))
        .font(.caption2)
        .foregroundStyle(secondaryText)
    }
    .padding(12)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(LinearGradient(
          colors: theme.isDarkRedesign
            ? [theme.cobaltStart, theme.cobaltEnd]
            : [Color.accentColor.opacity(0.07), Color.accentColor.opacity(0.07)],
          startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(presentation.stale ? Color.orange.opacity(0.55) : Color.accentColor.opacity(0.35), lineWidth: 1)
    }
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
      NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 2, height: 2)).fill()
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
        .foregroundStyle(theme.isDarkRedesign ? theme.darkSecondaryText : Color(nsColor: .secondaryLabelColor))
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .font(.title3.weight(.semibold))
        .foregroundStyle(theme.isDarkRedesign ? theme.darkPrimaryText : Color(nsColor: .labelColor))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background {
      if theme.isDarkRedesign {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.elevatedSurface)
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35))
      }
    }
    .overlay {
      if theme.isDarkRedesign {
        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.darkHairline, lineWidth: 1)
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
      Text(title).lineLimit(1)
      Spacer(minLength: 12)
      if isLoading {
        ProgressView().controlSize(.small)
      } else if let shortcut {
        if theme.isDarkRedesign {
          Text(shortcut).foregroundStyle(theme.darkTertiaryText)
        } else {
          Text(shortcut).foregroundStyle(.tertiary)
        }
      }
    }
    .foregroundStyle(theme.isDarkRedesign ? theme.darkPrimaryText : Color(nsColor: .labelColor))
    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .background(
      isHovered ? (theme.isDarkRedesign ? Color.white.opacity(0.07) : Color.primary.opacity(0.08)) : .clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
  }
}
