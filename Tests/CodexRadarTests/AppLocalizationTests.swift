import Foundation
import Testing

@testable import CodexRadar

struct AppLocalizationTests {
  @Test
  func localizesSettingsTitlesForTheExplicitLanguage() {
    #expect(
      AppLocalization.string("Settings", language: .english, bundle: .module) == "Settings"
    )
    #expect(
      AppLocalization.string("Settings", language: .simplifiedChinese, bundle: .module) == "设置"
    )
  }
}
