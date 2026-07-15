import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let defaultsKey = "appAppearance"

  var id: String { rawValue }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      nil
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  static func resolve(_ storedValue: String) -> AppAppearance {
    AppAppearance(rawValue: storedValue) ?? .system
  }
}
