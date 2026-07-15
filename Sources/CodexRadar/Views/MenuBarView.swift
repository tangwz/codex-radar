import AppKit
import SwiftUI

enum MenuActionID: String, CaseIterable, Equatable {
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

      Divider()

      Button("Open Dashboard") {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
      }

      Button("Check Now") {
        Task { await store.refresh() }
      }
      .disabled(store.isRefreshing)

      SettingsLink {
        Text("Settings…")
      }

      Link("Open Prediction Source", destination: store.forecast.sourceURL)

      Divider()

      Button("Quit Codex Radar") {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
    .padding(16)
    .frame(width: 300)
    .task {
      store.startMonitoring()
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
