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
}
