import SwiftUI

struct ContentView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var historyStore: ResetHistoryStore
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        ResetForecastCard(forecast: store.forecast)
        ResetHistoryView(store: historyStore, timeZone: timeZone)
        TokenUsageView(events: store.tokenEvents)

        if !store.issues.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(store.issues, id: \.self) { issue in
              Label(issue, systemImage: "exclamationmark.triangle")
            }
          }
          .font(.caption)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(24)
    }
    .frame(minWidth: 760, minHeight: 620)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          historyStore.refresh(timeZone: timeZone)
          Task { await store.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(store.isRefreshing)
      }
    }
    .overlay {
      if store.isRefreshing && store.tokenEvents.isEmpty {
        ProgressView("Reading Codex usage")
          .padding(18)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .onAppear {
      store.startMonitoring()
      historyStore.dashboardDidAppear(
        timeZone: timeZone,
        lastResetAt: store.forecast.lastResetAt
      )
    }
    .onDisappear {
      historyStore.dashboardDidDisappear()
    }
    .onChange(of: timeZone.identifier) {
      historyStore.refresh(timeZone: timeZone)
    }
    .onChange(of: store.forecast.lastResetAt) {
      historyStore.lastResetDidChange(store.forecast.lastResetAt, timeZone: timeZone)
    }
  }
}
