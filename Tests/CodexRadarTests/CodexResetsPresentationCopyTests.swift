import Foundation
import Testing

@testable import CodexRadar

struct CodexResetsPresentationCopyTests {
  @Test
  func localizesAnnouncementCountsAndAvailabilityWithoutAccountClaims() {
    let translations = [
      ("monthSummary", "%@, %lld announcements", "%@，%lld 条公告"),
      ("historyInfo", "About announcement statistics", "关于公告统计"),
      ("loadingHistory", "Loading announcement statistics", "正在加载公告统计"),
      ("historyUnavailable", "Announcement history unavailable", "公告历史暂不可用"),
      ("type", "Announcement type", "公告类型"),
      ("radarTitle", "Announcement radar", "公告雷达"),
      ("noAnnouncement", "No recorded announcement", "无公告记录"),
      ("regularAnnouncement", "Regular announcement", "普通重置公告"),
      ("bankedAnnouncement", "Banked announcement", "重置券公告"),
      ("mixedDay", "Both types on this day", "同日有两类公告"),
      ("radarUnavailable", "Announcement radar unavailable", "公告雷达暂不可用"),
      ("dataSource", "Reset data source", "重置数据来源"),
    ]
    for (key, english, chinese) in translations {
      #expect(CodexResetsCopy.text(key, locale: Locale(identifier: "en_US")) == english)
      #expect(CodexResetsCopy.text(key, locale: Locale(identifier: "zh_Hans")) == chinese)
    }
  }

  @Test
  func allAnnouncementsMeansRegularPlusBankedRatherThanSimultaneousResets() throws {
    let page = try APIJSONCoding.makeDecoder().decode(
      CodexResetsPage.self,
      from: publicPage(records: [
        publicRecord(id: "regular-1", kind: "regular"),
        publicRecord(id: "banked-1"),
        publicRecord(id: "banked-2"),
      ])
    )
    let history = try ResetHistory(
      codexResets: page.data, now: publicAPINow,
      timeZone: TimeZone(secondsFromGMT: 0)!, range: .sixMonths
    )
    let presentation = ResetHistoryPresentation(
      history: history, selectedRange: .sixMonths, metric: .both,
      locale: Locale(identifier: "en_US")
    )
    #expect(presentation.weekCount == 3)
    #expect(presentation.monthCount == 3)
    #expect(presentation.months.last?.count == 3)
    #expect(CodexResetsCopy.text("all", locale: Locale(identifier: "zh_Hans")) == "全部公告")
  }

  @Test
  func historyViewUsesAnnouncementCopyForPickerChartsAndAccessibility() throws {
    let source = try viewSource("ResetHistoryView.swift")
    for key in ["all", "regular", "banked", "statistics", "byMonth", "regularByMonth",
                "bankedByMonth", "historyNote", "monthSummary", "attribution"] {
      #expect(source.contains("CodexResetsCopy.text(\"\(key)\""))
    }
    #expect(!source.contains("Text(\"Both\")"))
    #expect(!source.contains("String(localized: \"Both\""))
    #expect(!source.contains("Hard + banked resets by month"))
  }

  @Test
  func radarLabelsDescribeAnnouncementsNotVerifiedQuotaChanges() throws {
    let source = try viewSource("ResetRadarView.swift")
    for key in ["regularAnnouncement", "bankedAnnouncement", "mixedDay", "noAnnouncement"] {
      #expect(source.contains("CodexResetsCopy.text(\"\(key)\""))
    }
    #expect(!source.contains("String(localized: \"No reset\""))
  }

  @Test
  func settingsDiscloseThirdPartySourceAndNonRealtimeRefresh() throws {
    let source = try viewSource("SettingsView.swift")
    #expect(source.contains("CodexResetsCopy.text(\"dataSource\""))
    #expect(source.contains("CodexResetsCopy.text(\"refreshNotice\""))
  }

  private func viewSource(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent("Sources/CodexRadar/Views/" + name), encoding: .utf8)
  }
}
