import AppKit
import SwiftUI

enum MenuActionID: String, CaseIterable, Hashable {
  case source
  case dashboard
  case refresh
  case settings
  case quit

  static let contextAction = MenuActionID.source
  static let applicationActions: [MenuActionID] = [.dashboard, .refresh, .settings, .quit]
}

struct MenuBarView: View {
  @ObservedObject var store: DashboardStore
  @Environment(\.openWindow) private var openWindow
  @Environment(\.locale) private var locale

  private var todayTokens: Int {
    TokenUsageAggregator.total(store.tokenEvents, in: .day)
  }

  private var monthTokens: Int {
    TokenUsageAggregator.total(store.tokenEvents, in: .month)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(
              store.forecast.isActive ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.14))
          Image(systemName: store.forecast.isActive ? "bell.badge.fill" : "scope")
            .foregroundStyle(store.forecast.isActive ? Color.red : Color.accentColor)
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: 2) {
          Text(
            store.forecast.isActive
              ? LocalizedStringKey("Reset incoming")
              : LocalizedStringKey("Reset monitoring")
          )
          .font(.headline)
          if let predictedAt = store.forecast.predictedAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
              Text(
                DisplayFormatting.countdown(to: predictedAt, from: context.date, locale: locale)
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
            }
          } else {
            Text("No active official window")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        if store.isRefreshing {
          ProgressView()
            .controlSize(.small)
        }
      }

      HStack(spacing: 10) {
        MenuMetric(title: "Today", value: todayTokens)
        MenuMetric(title: "This month", value: monthTokens)
      }

      VStack(alignment: .leading, spacing: 2) {
        actionControl(MenuActionID.contextAction)

        Divider()
          .padding(.vertical, 4)

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
    case .source:
      Button {
        NSWorkspace.shared.open(store.forecast.sourceURL)
      } label: {
        MenuActionRow(
          title: "Open Prediction Source",
          systemImage: "link",
          showsExternalLink: true
        )
      }
      .buttonStyle(.plain)

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

struct MenuBarLabel: View {
  let hasResetAlert: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Image(systemName: "scope")
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
  var showsExternalLink = false
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
      } else if showsExternalLink {
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
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
