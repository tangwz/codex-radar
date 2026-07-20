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

  @Test
  func localizesUpdateControlsInEnglish() {
    #expect(localized("Updates", language: .english) == "Updates")
    #expect(
      localized("Automatically check for updates", language: .english)
        == "Automatically check for updates"
    )
    #expect(
      localized("Check for Updates…", language: .english) == "Check for Updates…"
    )
    #expect(
      localized("Updates are available in release builds only.", language: .english)
        == "Updates are available in release builds only."
    )
    #expect(
      localized(
        "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates.",
        language: .english
      )
        == "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates."
    )
  }

  @Test
  func localizesUpdateControlsInSimplifiedChinese() {
    #expect(localized("Updates", language: .simplifiedChinese) == "更新")
    #expect(
      localized("Automatically check for updates", language: .simplifiedChinese)
        == "自动检查更新"
    )
    #expect(
      localized("Check for Updates…", language: .simplifiedChinese) == "检查更新…"
    )
    #expect(
      localized("Updates are available in release builds only.", language: .simplifiedChinese)
        == "更新功能仅在发布版本中可用。"
    )
    #expect(
      localized(
        "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates.",
        language: .simplifiedChinese
      )
        == "退出 CodexRadar，然后将其移至 /Applications 或 ~/Applications，再检查更新。"
    )
  }

  private func localized(_ key: String, language: AppLanguage) -> String {
    AppLocalization.string(key, language: language, bundle: .module)
  }
}
