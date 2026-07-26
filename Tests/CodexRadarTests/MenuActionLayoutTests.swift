import AppKit
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
  func usesAFullBleedColorMenuBarIcon() {
    #expect(MenuBarIconConfiguration.assetName == "MenuBarIcon")
    #expect(MenuBarIconConfiguration.sideLength == 18)
    #expect(MenuBarIconConfiguration.contentInset == 0)
  }

  @Test
  @MainActor
  func providesMenuBarIconAtConfiguredLogicalSize() {
    #expect(
      MenuBarIconConfiguration.image.size
        == NSSize(
          width: MenuBarIconConfiguration.sideLength,
          height: MenuBarIconConfiguration.sideLength
        )
    )
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
}

@MainActor
private func makeStore() -> DashboardStore {
  DashboardStore(
    scanSessions: { [] },
    fetchForecast: { _ in .notModified },
    prepareNotifications: {},
    observeForecast: { _ in },
    formatForecastIssue: { $0 ?? "" },
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: { _ in },
    observesWakeEvents: false
  )
}
