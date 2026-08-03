import Foundation
import Testing

struct ResetRadarViewTests {
  @Test
  func rendersAFullWidthFifteenByTwoGrid() throws {
    let source = try resetRadarViewSource()

    #expect(source.contains("GridItem(.flexible(minimum: 20), spacing: 8)"))
    #expect(source.contains("count: 15"))
    #expect(source.contains("LazyVGrid(columns: columns"))
    #expect(source.contains("Text(\"Last 30 days\")"))
    #expect(source.contains(".aspectRatio(1, contentMode: .fit)"))
  }

  @Test
  func usesTheSemanticResetPaletteForCellsAndLegend() throws {
    let source = try resetRadarViewSource()

    #expect(source.contains("static let inactive = Color.secondary.opacity(0.12)"))
    #expect(source.contains("static let hard = Color.green.opacity(0.48)"))
    #expect(source.contains("static let banked = Color.green.opacity(0.70)"))
    #expect(source.contains("static let hardAndBanked = Color.green.opacity(0.92)"))
    #expect(source.contains("static let todayOutline = Color.primary.opacity(0.70)"))
  }

  @Test
  func rendersTodayOrLatestAndOnlyOutlinesToday() throws {
    let source = try resetRadarViewSource()

    #expect(source.contains("switch presentation.endMarker"))
    #expect(source.contains("Today · %@"))
    #expect(source.contains("Latest · %@"))
    #expect(source.contains("day.isToday ? ResetRadarPalette.todayOutline : .clear"))
    #expect(source.contains("lineWidth: day.isToday ? 2 : 0"))
  }

  @Test
  func supportsOneSharedHoverAndKeyboardSelection() throws {
    let source = try resetRadarViewSource()

    #expect(source.contains("@FocusState private var focusedDayID: String?"))
    #expect(source.contains(".onHover"))
    #expect(source.contains(".focusable()"))
    #expect(source.contains(".focused($focusedDayID"))
    #expect(source.contains(".accessibilityLabel"))
    #expect(source.contains("selectedDayID"))
    #expect(!source.contains(".help("))
  }

  @Test
  func omitsLegacyRecordsAndExplanatoryCards() throws {
    let source = try resetRadarViewSource()

    #expect(!source.contains("Recent resets"))
    #expect(!source.contains("Reset completed"))
    #expect(!source.contains("Multiple types"))
    #expect(!source.contains("At least one completed"))
  }

  private func resetRadarViewSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/CodexRadar/Views/ResetRadarView.swift"
      ),
      encoding: .utf8
    )
  }
}
