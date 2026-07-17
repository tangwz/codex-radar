import Testing

@testable import CodexRadar

@MainActor
struct SettingsNavigationTests {
  @Test
  func keepsTheSettingsPaneOrderStable() {
    #expect(SettingsPane.allCases == [.dashboard, .settings, .about])
  }

  @Test
  func startsOnSettingsAndSupportsExplicitRouting() {
    let selection = SettingsSelection()

    #expect(selection.pane == .settings)

    selection.show(.about)
    #expect(selection.pane == .about)

    selection.show(.dashboard)
    #expect(selection.pane == .dashboard)
  }

  @Test
  func providesStablePresentationMetadata() {
    #expect(SettingsPane.dashboard.titleKey == "Dashboard")
    #expect(SettingsPane.dashboard.systemImage == "chart.xyaxis.line")
    #expect(SettingsPane.settings.titleKey == "Settings")
    #expect(SettingsPane.settings.systemImage == "gearshape.fill")
    #expect(SettingsPane.about.titleKey == "About")
    #expect(SettingsPane.about.systemImage == "info.circle.fill")
  }
}
