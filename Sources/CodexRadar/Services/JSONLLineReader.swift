import Foundation

struct JSONLLineReader: Sendable {
  func forEachLine(at fileURL: URL, body: (Data) throws -> Void) throws {
    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    var lineStart = data.startIndex

    while lineStart < data.endIndex {
      let newline = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex

      if newline > lineStart {
        try body(data[lineStart..<newline])
      }

      guard newline < data.endIndex else {
        return
      }
      lineStart = data.index(after: newline)
    }
  }
}
