import Foundation

enum AppLocalization {
  static func string(_ key: String) -> String {
    string(key, language: AppLanguage.selected)
  }

  static func string(
    _ key: String,
    language: AppLanguage,
    bundle: Bundle = .main
  ) -> String {
    let localizedBundle: Bundle

    switch language {
    case .system:
      localizedBundle = bundle
    case .english, .simplifiedChinese:
      let languageCode = bundle.localizations.first {
        $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
      } ?? language.rawValue
      localizedBundle =
        bundle.path(forResource: languageCode, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? bundle
    }

    return localizedBundle.localizedString(forKey: key, value: nil, table: nil)
  }
}
