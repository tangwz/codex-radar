import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  static let defaultsKey = "appLanguage"

  var id: Self { self }

  var locale: Locale {
    switch self {
    case .system: .current
    case .english: Locale(identifier: "en")
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    }
  }

  static var selected: AppLanguage {
    let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? AppLanguage.system.rawValue
    return AppLanguage(rawValue: stored) ?? .system
  }

}
