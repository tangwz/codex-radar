import AppKit
import SwiftUI
import Testing

@testable import CodexRadar

struct MenuActionLayoutTests {
  @MainActor
  @Test
  func refreshActionInvokesBothDataSources() async {
    var dashboardRefreshCount = 0
    var historyRefreshCount = 0
    let action = MenuRefreshAction(
      refreshDashboard: {
        dashboardRefreshCount += 1
      },
      refreshHistory: {
        historyRefreshCount += 1
      }
    )

    await action.perform()

    #expect(dashboardRefreshCount == 1)
    #expect(historyRefreshCount == 1)
  }

  @Test
  func keepsOnlyApplicationActionsInTheMenuList() {
    #expect(MenuActionID.allCases == [.refresh, .dashboard, .settings, .about, .quit])
    #expect(MenuActionID.applicationActions == MenuActionID.allCases)
  }

  @Test
  @MainActor
  func providesTemplateRadarMenuBarIcon() throws {
    let image = MenuBarIconConfiguration.image
    let data = try #require(image.tiffRepresentation)

    #expect(MenuBarIconConfiguration.sideLength == 18)
    #expect(
      image.size
        == NSSize(
          width: MenuBarIconConfiguration.sideLength,
          height: MenuBarIconConfiguration.sideLength
        )
    )
    #expect(image.isTemplate)
    #expect(data.isEmpty == false)
  }

  @Test
  @MainActor
  func reusesTheMenuBarIconImageInstance() {
    #expect(MenuBarIconConfiguration.image === MenuBarIconConfiguration.image)
  }

  @Test
  @MainActor
  func constructsTheMenuBarViewWithInjectedPanelActions() {
    let actions = MenuBarPanelActions(
      dismissPanel: {},
      openURL: { _ in true },
      selectSettingsPane: { _ in },
      activateApplication: {},
      openSettingsWindow: { true },
      terminateApplication: {},
      reportFailure: { _ in }
    )

    let store = makeStore()
    let historyStore = ResetHistoryStore()
    let menuBarView = MenuBarView(
      store: store,
      historyStore: historyStore,
      actions: actions
    )
    let rootView = MenuBarPanelRootView(
      store: store,
      historyStore: historyStore,
      actions: actions
    )

    #expect(menuBarView.store === store)
    #expect(menuBarView.historyStore === historyStore)
    #expect(rootView.store === store)
    #expect(rootView.historyStore === historyStore)
  }

  @Test
  @MainActor
  func timeZoneChangeRefreshesMenuTokenUsage() async throws {
    let initialTimeZone = try #require(TimeZone(identifier: "Etc/UTC"))
    let updatedTimeZone = try #require(TimeZone(identifier: "Pacific/Honolulu"))
    let recorder = MenuTokenUsageTimeZoneRecorder()
    let store = DashboardStore(
      refreshTokenUsageSource: { timeZone, _ in
        await recorder.record(timeZone)
        return TokenUsageRepositoryResult(
          snapshot: TokenUsageSnapshotBuilder.make(
            events: [],
            at: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: timeZone
          ),
          issues: []
        )
      },
      fetchForecast: { _ in .notModified },
      prepareNotifications: {},
      observeForecast: { _ in },
      formatForecastIssue: { $0 ?? "" },
      pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
      sleep: { _ in },
      observesWakeEvents: false
    )
    let historyStore = ResetHistoryStore()
    let actions = MenuBarPanelActions(
      dismissPanel: {},
      openURL: { _ in true },
      selectSettingsPane: { _ in },
      activateApplication: {},
      openSettingsWindow: { true },
      terminateApplication: {},
      reportFailure: { _ in }
    )
    let hostingView = NSHostingView(
      rootView: MenuBarView(
        store: store,
        historyStore: historyStore,
        actions: actions
      )
      .environment(\.timeZone, initialTimeZone)
    )
    defer { store.stopMonitoring() }

    hostingView.layoutSubtreeIfNeeded()
    for _ in 0..<20 {
      await Task.yield()
    }
    hostingView.rootView = MenuBarView(
      store: store,
      historyStore: historyStore,
      actions: actions
    )
    .environment(\.timeZone, updatedTimeZone)
    hostingView.layoutSubtreeIfNeeded()
    for _ in 0..<100 {
      if await recorder.contains(updatedTimeZone.identifier),
        store.tokenUsageSnapshot?.timeZoneIdentifier == updatedTimeZone.identifier
      {
        break
      }
      await Task.yield()
    }

    #expect(await recorder.contains(updatedTimeZone.identifier))
    #expect(store.tokenUsageSnapshot?.timeZoneIdentifier == updatedTimeZone.identifier)
  }
}

private actor MenuTokenUsageTimeZoneRecorder {
  private var identifiers: [String] = []

  func record(_ timeZone: TimeZone) {
    identifiers.append(timeZone.identifier)
  }

  func contains(_ identifier: String) -> Bool {
    identifiers.contains(identifier)
  }
}

@MainActor
private func makeStore() -> DashboardStore {
  DashboardStore(
    fetchForecast: { _ in .notModified },
    prepareNotifications: {},
    observeForecast: { _ in },
    formatForecastIssue: { $0 ?? "" },
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: { _ in },
    observesWakeEvents: false
  )
}
