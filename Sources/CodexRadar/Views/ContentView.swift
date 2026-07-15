import SwiftUI

struct ContentView: View {
  @ObservedObject var store: DashboardStore

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        ResetForecastCard(forecast: store.forecast)
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
    .task {
      store.startMonitoring()
    }
  }
}
