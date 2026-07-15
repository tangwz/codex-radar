import Foundation

enum AppLocalization {
  static func string(_ key: String) -> String {
    let selected = AppLanguage.selected
    let bundle: Bundle

    switch selected {
    case .system:
      bundle = .main
    case .english, .simplifiedChinese:
      let languageCode = selected.rawValue
      bundle =
        Bundle.main.path(forResource: languageCode, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .main
    }

    return bundle.localizedString(forKey: key, value: nil, table: nil)
  }
}
