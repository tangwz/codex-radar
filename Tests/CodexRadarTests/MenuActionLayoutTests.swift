import Testing

@testable import CodexRadar

struct MenuActionLayoutTests {
  @Test
  func keepsOnlyApplicationActionsInTheMenuList() {
    #expect(MenuActionID.allCases == [.dashboard, .refresh, .settings, .quit])
    #expect(MenuActionID.applicationActions == MenuActionID.allCases)
  }
}
