import SwiftUI
import Testing

@testable import CodexRadar

struct MenuBarThemeTests {
  @Test
  func selectsGraphiteCobaltPresentationInDarkMode() {
    let theme = MenuBarTheme(colorScheme: .dark)

    #expect(theme.mode == .graphiteCobalt)
    #expect(theme.forecastEmphasis == .cobalt)
    #expect(theme.actionPresentation == .insetGroup)
  }

  @Test
  func preservesSystemPresentationInLightMode() {
    let theme = MenuBarTheme(colorScheme: .light)

    #expect(theme.mode == .system)
    #expect(theme.forecastEmphasis == .systemAccent)
    #expect(theme.actionPresentation == .plain)
  }
}
