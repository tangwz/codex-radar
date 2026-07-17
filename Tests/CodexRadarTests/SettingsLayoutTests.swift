import Testing

@testable import CodexRadar

struct SettingsLayoutTests {
  @Test
  func usesTheApprovedFixedDimensions() {
    #expect(SettingsLayout.sidebarWidth == 220)
    #expect(SettingsLayout.windowDefaultWidth == 1000)
    #expect(SettingsLayout.windowDefaultHeight == 720)
    #expect(SettingsLayout.windowMinWidth == 980)
    #expect(SettingsLayout.windowMinHeight == 620)
  }
}
