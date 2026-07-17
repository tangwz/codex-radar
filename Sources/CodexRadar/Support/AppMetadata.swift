import Foundation

struct AppMetadata: Equatable, Sendable {
  let version: String?
  let build: String?

  init(infoDictionary: [String: Any]) {
    version = Self.nonEmptyString(infoDictionary["CFBundleShortVersionString"])
    build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
  }

  static var current: AppMetadata {
    AppMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])
  }

  var versionString: String {
    guard let version else { return "—" }
    guard let build else { return version }
    return "\(version) (\(build))"
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct AboutLink: Identifiable, Equatable, Sendable {
  enum ID: String, Hashable, Sendable {
    case github
    case website
    case x
    case bilibili
  }

  let id: ID
  let titleKey: String
  let systemImage: String
  let url: URL

  static let all: [AboutLink] = [
    AboutLink(
      id: .github,
      titleKey: "GitHub",
      systemImage: "chevron.left.slash.chevron.right",
      url: makeURL("https://github.com/tangwz/codex-radar")
    ),
    AboutLink(
      id: .website,
      titleKey: "Website",
      systemImage: "globe",
      url: makeURL("https://codex-radar.tangwz.com")
    ),
    AboutLink(
      id: .x,
      titleKey: "X",
      systemImage: "bird",
      url: makeURL("https://x.com/shixtang")
    ),
    AboutLink(
      id: .bilibili,
      titleKey: "Bilibili",
      systemImage: "play.rectangle",
      url: makeURL("https://space.bilibili.com/19041535")
    ),
  ]

  private static func makeURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
      preconditionFailure("Invalid About URL: \(value)")
    }
    return url
  }
}
