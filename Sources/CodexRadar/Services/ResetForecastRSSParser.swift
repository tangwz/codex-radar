import Foundation

enum ResetForecastError: LocalizedError {
  case invalidFeed
  case missingItem
  case missingDate

  var errorDescription: String? {
    switch self {
    case .invalidFeed: "The reset feed is not valid XML."
    case .missingItem: "The reset feed has no announcements."
    case .missingDate: "The latest reset announcement has no valid date."
    }
  }
}

struct ResetForecastRSSParser: Sendable {
  func parse(data: Data, now: Date = .now) throws -> ResetForecast {
    let delegate = RSSDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate

    guard parser.parse() else {
      throw ResetForecastError.invalidFeed
    }
    guard let item = delegate.firstItem else {
      throw ResetForecastError.missingItem
    }
    guard let announcedAt = parseRFC822Date(item.publicationDate) else {
      throw ResetForecastError.missingDate
    }

    let sourceURL =
      extractSourceURL(from: item.description)
      ?? URL(string: item.link)
      ?? URL(string: "https://x.com/thsottiaux")!
    let durationHours = extractDurationHours(from: item.title + " " + item.description)
    let isOpenAnnouncement =
      item.title.localizedCaseInsensitiveContains("open")
      || item.title.contains("\u{5F00}\u{542F}")
    let deadline = durationHours.map { announcedAt.addingTimeInterval(TimeInterval($0 * 3_600)) }
    let isActive = isOpenAnnouncement && deadline.map { $0 > now } == true

    return ResetForecast(
      isActive: isActive,
      predictedAt: isActive ? deadline : nil,
      announcedAt: announcedAt,
      title: isActive ? "Official reset window" : "Awaiting the next signal",
      summary: isActive
        ? item.title
        : "The last announced reset window has ended. Monitoring remains active.",
      sourceURL: sourceURL
    )
  }

  private func parseRFC822Date(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }

  private func extractDurationHours(from value: String) -> Int? {
    let patterns = [
      #"(?i)within\s+(\d+)\s*hours?"#,
      "(\\d+)\\s*\\x{5C0F}\\x{65F6}",
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: value,
          range: NSRange(value.startIndex..., in: value)
        ),
        let range = Range(match.range(at: 1), in: value),
        let hours = Int(value[range])
      else {
        continue
      }
      return hours
    }
    return nil
  }

  private func extractSourceURL(from value: String) -> URL? {
    guard
      let regex = try? NSRegularExpression(
        pattern: #"https://(?:x\.com|twitter\.com)/[^\s<]+"#
      ),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let range = Range(match.range, in: value)
    else {
      return nil
    }
    return URL(string: String(value[range]).trimmingCharacters(in: .punctuationCharacters))
  }
}

private final class RSSDelegate: NSObject, XMLParserDelegate {
  struct Item {
    var title = ""
    var link = ""
    var publicationDate = ""
    var description = ""
  }

  private var currentElement = ""
  private var currentItem: Item?
  private(set) var firstItem: Item?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName
    if elementName == "item", firstItem == nil {
      currentItem = Item()
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    append(string)
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    append(String(decoding: CDATABlock, as: UTF8.self))
  }

  private func append(_ string: String) {
    guard currentItem != nil else { return }
    switch currentElement {
    case "title": currentItem?.title += string
    case "link": currentItem?.link += string
    case "pubDate": currentItem?.publicationDate += string
    case "description": currentItem?.description += string
    default: break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "item", firstItem == nil {
      firstItem = currentItem
      currentItem = nil
    }
    currentElement = ""
  }
}
