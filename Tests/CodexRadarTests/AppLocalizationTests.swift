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
      localized("A new CodexRadar update is available", language: .english)
        == "A new CodexRadar update is available"
    )
    #expect(
      localized("Version %@ is now available.", language: .english)
        == "Version %@ is now available."
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
      localized("A new CodexRadar update is available", language: .simplifiedChinese)
        == "CodexRadar \u{6709}\u{65B0}\u{7248}\u{672C}\u{53EF}\u{7528}"
    )
    #expect(
      localized("Version %@ is now available.", language: .simplifiedChinese)
        == "\u{7248}\u{672C} %@ \u{73B0}\u{5DF2}\u{53EF}\u{7528}\u{3002}"
    )
    #expect(
      localized(
        "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates.",
        language: .simplifiedChinese
      )
        == "退出 CodexRadar，然后将其移至 /Applications 或 ~/Applications，再检查更新。"
    )
  }

  @Test
  func buildsLocalizedInstallationAlertContentForProduction() {
    #expect(
      UpdateInstallationAlertContent.localized(language: .english, bundle: .module)
        == UpdateInstallationAlertContent(
          title: "CodexRadar cannot install updates from its current location.",
          message:
            "Quit CodexRadar, then move it to /Applications or ~/Applications before checking for updates.",
          buttonTitle: "OK"
        )
    )
    #expect(
      UpdateInstallationAlertContent.localized(language: .simplifiedChinese, bundle: .module)
        == UpdateInstallationAlertContent(
          title: "CodexRadar 无法从当前位置安装更新。",
          message: "退出 CodexRadar，然后将其移至 /Applications 或 ~/Applications，再检查更新。",
          buttonTitle: "确定"
        )
    )
  }

  private func localized(_ key: String, language: AppLanguage) -> String {
    AppLocalization.string(key, language: language, bundle: .module)
  }

  @Test
  func localizesNoResetHistoryForSimplifiedChinese() {
    #expect(
      AppLocalization.string("No reset history", language: .simplifiedChinese, bundle: .module)
        == "暂无重置记录"
    )
  }

  @Test
  func localizesResetStatisticsLabelsForBothLanguages() {
    let translations = [
      ("Reset statistics", "重置统计"),
      ("This week", "本周"),
      ("Resets by month", "按月重置次数"),
      ("Time range", "时间范围"),
      ("All", "全部"),
      ("About monthly reset statistics", "关于每月重置统计"),
      ("Months follow natural boundaries in your selected time zone.", "月份按所选时区的自然月边界统计。"),
      ("Recent resets", "最近重置"),
      ("Latest 5", "最近 5 条"),
      ("Loading reset statistics", "正在加载重置统计"),
      ("Reset history unavailable", "重置历史暂不可用"),
      ("Retry", "重试"),
      ("Reset history is temporarily unavailable.", "重置历史暂时不可用。"),
    ]

    for (key, simplifiedChinese) in translations {
      #expect(AppLocalization.string(key, language: .english, bundle: .module) == key)
      #expect(
        AppLocalization.string(key, language: .simplifiedChinese, bundle: .module)
          == simplifiedChinese
      )
    }
  }
}
