import Foundation
import Testing

@testable import CodexRadar

struct ResetHistoryRefreshScheduleTests {
  @Test
  func choosesNextLocalDayBoundaryOnOrdinaryWeekday() throws {
    let generatedAt = try date("2026-07-22T09:00:00Z")
    let expected = try date("2026-07-22T16:00:01Z")
    let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))

    #expect(
      ResetHistoryRefreshSchedule.nextBoundary(after: generatedAt, timeZone: zone)
        == expected)
  }

  @Test
  func choosesNextLocalDayAtMonthEnd() throws {
    let generatedAt = try date("2026-07-31T12:00:00Z")
    let expected = try date("2026-07-31T16:00:01Z")
    let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))

    #expect(
      ResetHistoryRefreshSchedule.nextBoundary(after: generatedAt, timeZone: zone)
        == expected)
  }

  @Test
  func convertsLocalBoundariesToCorrectAbsoluteDates() throws {
    let generatedAt = try date("2026-07-31T12:00:00Z")
    let expectedShanghai = try date("2026-07-31T16:00:01Z")
    let expectedLosAngeles = try date("2026-08-01T07:00:01Z")
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))

    #expect(
      ResetHistoryRefreshSchedule.nextBoundary(after: generatedAt, timeZone: shanghai)
        == expectedShanghai)
    #expect(
      ResetHistoryRefreshSchedule.nextBoundary(after: generatedAt, timeZone: losAngeles)
        == expectedLosAngeles)
  }

  @Test
  func targetsLocalMidnightAcrossDSTTransition() throws {
    let generatedAt = try date("2026-03-07T20:00:00Z")
    let expected = try date("2026-03-08T08:00:01Z")
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))

    #expect(
      ResetHistoryRefreshSchedule.nextBoundary(after: generatedAt, timeZone: zone)
        == expected)
  }

  @Test
  func alwaysReturnsABoundaryStrictlyAfterGeneratedAt() throws {
    let generatedAt = try date("2026-08-01T07:00:00Z")
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let boundary = try #require(
      ResetHistoryRefreshSchedule.nextBoundary(after: generatedAt, timeZone: zone))

    #expect(boundary > generatedAt)
  }
}

private func date(_ value: String) throws -> Date {
  try #require(ISO8601DateFormatter().date(from: value))
}
