import Foundation
import Testing

@testable import CodexRadar

struct JSONLLineReaderTests {
  @Test
  func emitsCompleteLinesAndKeepsFinalLine() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data("first\nsecond line\nthird".utf8).write(to: fileURL)
    var lines: [String] = []

    try JSONLLineReader().forEachLine(at: fileURL) { line in
      lines.append(String(decoding: line, as: UTF8.self))
    }

    #expect(lines == ["first", "second line", "third"])
  }
}
