import SwiftUI

struct SettingsView: View {
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  var body: some View {
    Form {
      Picker("Language", selection: $language) {
        Text("System Default").tag(AppLanguage.system.rawValue)
        Text("English").tag(AppLanguage.english.rawValue)
        Text("Simplified Chinese").tag(AppLanguage.simplifiedChinese.rawValue)
      }

      Picker("Appearance", selection: $appearance) {
        Text("System Default").tag(AppAppearance.system.rawValue)
        Text("Light").tag(AppAppearance.light.rawValue)
        Text("Dark").tag(AppAppearance.dark.rawValue)
      }

      LabeledContent("Reset alerts") {
        Text("Menu bar badge and notifications")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440, height: 220)
    .navigationTitle("General")
  }
}
