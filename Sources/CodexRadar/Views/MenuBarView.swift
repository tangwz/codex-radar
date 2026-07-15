import AppKit
import SwiftUI

enum MenuActionID: String, CaseIterable, Hashable {
  case dashboard
  case refresh
  case settings
  case quit

  static let applicationActions = MenuActionID.allCases
}

struct MenuBarView: View {
  @ObservedObject var store: DashboardStore
  @Environment(\.openWindow) private var openWindow

  private var todayTokens: Int {
    TokenUsageAggregator.total(store.tokenEvents, in: .day)
  }

  private var monthTokens: Int {
    TokenUsageAggregator.total(store.tokenEvents, in: .month)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MenuResetPredictionCard(forecast: store.forecast, isRefreshing: store.isRefreshing)

      HStack(spacing: 10) {
        MenuMetric(title: "Today", value: todayTokens)
        MenuMetric(title: "This month", value: monthTokens)
      }

      Divider()

      VStack(alignment: .leading, spacing: 2) {
        ForEach(MenuActionID.applicationActions, id: \.self) { action in
          actionControl(action)
        }
      }
    }
    .padding(16)
    .frame(width: 300)
    .task {
      store.startMonitoring()
    }
  }

  @ViewBuilder
  private func actionControl(_ action: MenuActionID) -> some View {
    switch action {
    case .dashboard:
      Button {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        MenuActionRow(
          title: "Open Dashboard",
          systemImage: "rectangle.grid.2x2",
          shortcut: "⌘D"
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut("d", modifiers: .command)

    case .refresh:
      Button {
        Task { await store.refresh() }
      } label: {
        MenuActionRow(
          title: "Check Now",
          systemImage: "arrow.clockwise",
          shortcut: "⌘R",
          isLoading: store.isRefreshing
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut("r", modifiers: .command)
      .disabled(store.isRefreshing)

    case .settings:
      SettingsLink {
        MenuActionRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,")
      }
      .buttonStyle(.plain)
      .keyboardShortcut(",", modifiers: .command)

    case .quit:
      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        MenuActionRow(title: "Quit", systemImage: "power", shortcut: "⌘Q")
      }
      .buttonStyle(.plain)
      .keyboardShortcut("q", modifiers: .command)
    }
  }
}

private struct MenuResetPredictionCard: View {
  let forecast: ResetForecast
  let isRefreshing: Bool
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 10) {
        RadarLogo(isActive: forecast.isActive)

        VStack(alignment: .leading, spacing: 3) {
          Text("Next reset forecast")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .layoutPriority(1)

          if let predictedAt = forecast.predictedAt {
            Text(
              predictedAt,
              format: .dateTime
                .month(.abbreviated)
                .day()
                .weekday(.abbreviated)
                .locale(locale)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        Spacer(minLength: 4)

        if isRefreshing {
          ProgressView()
            .controlSize(.small)
            .frame(minHeight: 22)
        } else {
          ResetStatusBadge(isActive: forecast.isActive)
        }
      }

      if let predictedAt = forecast.predictedAt {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(
              predictedAt,
              format: .dateTime
                .hour()
                .minute()
                .locale(locale)
            )
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)

            Spacer(minLength: 2)

            Text(
              String(
                format: String(localized: "About %@", bundle: .main, locale: locale),
                DisplayFormatting.countdown(to: predictedAt, from: context.date, locale: locale)
              )
            )
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 3) {
          Text("No active official window")
            .font(.title3.weight(.semibold))
          Text("Waiting for the next official signal")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Link(destination: forecast.sourceURL) {
        PredictionSourceChip()
      }
      .buttonStyle(.plain)
    }
    .padding(12)
    .background(
      Color.accentColor.opacity(0.07),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          forecast.isActive ? Color.red.opacity(0.5) : Color.accentColor.opacity(0.35),
          lineWidth: 1
        )
    }
  }
}

private struct RadarLogo: View {
  let isActive: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.accentColor.opacity(0.16))

      ForEach([0.38, 0.62, 0.84], id: \.self) { scale in
        Circle()
          .stroke(Color.accentColor.opacity(0.85), lineWidth: 1.4)
          .scaleEffect(scale)
      }

      Capsule()
        .fill(Color.accentColor)
        .frame(width: 25, height: 2)
        .offset(x: 8)
        .rotationEffect(.degrees(-45))

      Circle()
        .fill(Color.accentColor)
        .frame(width: 7, height: 7)
    }
    .frame(width: 46, height: 46)
    .overlay(alignment: .topTrailing) {
      if isActive {
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
  let isActive: Bool

  var body: some View {
    Text(isActive ? LocalizedStringKey("Reset incoming") : LocalizedStringKey("Monitoring"))
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .foregroundStyle(isActive ? Color.red : Color.accentColor)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(
        isActive ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.1),
        in: Capsule()
      )
  }
}

private struct PredictionSourceChip: View {
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
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .background(
      isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
  }
}

enum MenuBarIconConfiguration {
  static let assetName = "MenuBarIcon"
  static let sideLength: CGFloat = 18
  static let contentInset: CGFloat = 0

  static var image: NSImage {
    let resourceURL = Bundle.main.url(forResource: assetName, withExtension: "png")
      ?? Bundle.module.url(forResource: assetName, withExtension: "png")

    if let image = resourceURL.flatMap(NSImage.init(contentsOf:)) {
      return image
    }

    return NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
      ?? NSImage(size: NSSize(width: sideLength, height: sideLength))
  }
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
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(DisplayFormatting.tokenCount(value, locale: locale))
        .font(.title3.weight(.semibold))
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct MenuActionRow: View {
  let title: LocalizedStringKey
  let systemImage: String
  var shortcut: String?
  var isLoading = false
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
        Text(shortcut)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .background(
      isHovered ? Color.primary.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .onHover { isHovered = $0 }
  }
}
