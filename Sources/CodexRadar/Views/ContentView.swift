import SwiftUI

struct ContentView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var historyStore: ResetHistoryStore
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        refreshControl

        VStack(spacing: 18) {
          ResetForecastCard(forecast: store.forecast)
          ResetHistoryView(store: historyStore, timeZone: timeZone)
          TokenUsageView(snapshot: store.tokenUsageSnapshot)

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
        .padding(.top, 12)
      }
      .padding(24)
    }
    .frame(minWidth: 760, minHeight: 620)
    .overlay {
      if store.isRefreshing && store.tokenUsageSnapshot == nil {
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
      Task {
        await store.refreshTokenUsage(timeZone: timeZone)
      }
    }
    .onChange(of: store.forecast.lastResetAt) {
      historyStore.lastResetDidChange(store.forecast.lastResetAt, timeZone: timeZone)
    }
  }

  private var refreshControl: some View {
    HStack {
      Spacer()

      Button {
        historyStore.refresh(timeZone: timeZone)
        Task { await store.refresh() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .keyboardShortcut("r", modifiers: .command)
      .disabled(store.isRefreshing)
    }
  }
}
