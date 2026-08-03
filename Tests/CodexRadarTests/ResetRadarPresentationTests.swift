import Foundation
import Testing

@testable import CodexRadar

struct ResetRadarPresentationTests {
  private let locale = Locale(identifier: "en_US")

  @Test
  func v11HistoryHasNoRadarPresentation() throws {
    let history = try decodeResetHistory(resetHistoryJSON())

    #expect(ResetRadarPresentation(history: history, locale: locale) == nil)
  }

  @Test
  func mapsAllKindsAndCountsActiveDaysInsteadOfEvents() throws {
    let days = resetHistoryDayJSONs(
      activeKinds: [0: .hard(5), 1: .banked(4), 2: .hardAndBanked(3)]
    )
    let history = try decodeResetHistory(resetHistoryV12JSON(days: days))
    let now = ISO8601DateFormatter().date(from: "2026-07-19T10:00:00Z")!
    let presentation = try #require(
      ResetRadarPresentation(history: history, locale: locale, now: now))

    #expect(presentation.days.count == 30)
    #expect(
      Array(presentation.days.prefix(4).map(\.kind))
        == [.hard, .banked, .hardAndBanked, .inactive])
    #expect(presentation.activeDayCount == 3)
    #expect(presentation.days.map(\.id) == history.radarDays?.map(\.day))
  }

  @Test
  func freshSnapshotMarksOnlyTheFinalDayAsToday() throws {
    let history = try decodeResetHistory(resetHistoryV12JSON())
    let now = ISO8601DateFormatter().date(from: "2026-07-19T15:59:59Z")!
    let presentation = try #require(
      ResetRadarPresentation(history: history, locale: locale, now: now))

    #expect(presentation.endMarker == .today)
    #expect(presentation.days.filter(\.isToday).map(\.id) == ["2026-07-19"])
  }

  @Test
  func retainedSnapshotAfterLocalMidnightUsesLatestWithoutToday() throws {
    let history = try decodeResetHistory(resetHistoryV12JSON())
    let nextLocalMidnight = ISO8601DateFormatter().date(from: "2026-07-19T16:00:00Z")!
    let presentation = try #require(
      ResetRadarPresentation(
        history: history,
        locale: locale,
        now: nextLocalMidnight
      ))

    #expect(presentation.endMarker == .latest)
    #expect(presentation.days.allSatisfy { !$0.isToday })
  }

  @Test
  func todayDecisionAndLabelsUseTheResponseTimeZone() throws {
    let generatedAt = "2026-07-19T23:00:00Z"
    let history = try decodeResetHistory(
      resetHistoryV12JSON(generatedAt: generatedAt))
    let now = ISO8601DateFormatter().date(from: generatedAt)!
    let presentation = try #require(
      ResetRadarPresentation(history: history, locale: locale, now: now))

    #expect(presentation.days.last?.id == "2026-07-20")
    #expect(presentation.days.last?.isToday == true)
    #expect(presentation.days.last?.dateLabel.contains("July 20, 2026") == true)
    #expect(presentation.startLabel == "Jun 21")
    #expect(presentation.endLabel == "Jul 20")
  }
}

private func decodeResetHistory(_ json: String) throws -> ResetHistory {
  try APIJSONCoding.makeDecoder().decode(ResetHistory.self, from: Data(json.utf8))
}
