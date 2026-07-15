import Testing

@testable import CodexRadar

struct MenuActionLayoutTests {
  @Test
  func keepsPredictionSourceBeforeTheApplicationActionGroup() {
    #expect(MenuActionID.contextAction == .source)
    #expect(MenuActionID.applicationActions == [.dashboard, .refresh, .settings, .quit])
  }
}
