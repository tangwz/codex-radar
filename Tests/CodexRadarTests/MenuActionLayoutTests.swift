import AppKit
import Testing

@testable import CodexRadar

struct MenuActionLayoutTests {
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
  func reusesTheMenuBarIconImageInstance() {
    #expect(MenuBarIconConfiguration.image === MenuBarIconConfiguration.image)
  }
}
