import SwiftUI
import Testing

@testable import CodexRadar

@Suite("AppAppearanceTests")
struct AppAppearanceTests {
  @Test("maps stored values to preferred color schemes")
  func mapsStoredValuesToPreferredColorSchemes() {
    #expect(AppAppearance.system.colorScheme == nil)
    #expect(AppAppearance.light.colorScheme == .light)
    #expect(AppAppearance.dark.colorScheme == .dark)
  }

  @Test("falls back to system appearance for an unknown stored value")
  func fallsBackToSystemAppearanceForUnknownStoredValue() {
    #expect(AppAppearance.resolve("unknown") == .system)
  }
}
