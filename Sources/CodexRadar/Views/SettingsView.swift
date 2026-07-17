import AppKit
import SwiftUI

enum SettingsLayout {
  static let sidebarWidth: CGFloat = 220
  static let windowDefaultWidth: CGFloat = 1000
  static let windowDefaultHeight: CGFloat = 720
  static let windowMinWidth: CGFloat = 980
  static let windowMinHeight: CGFloat = 620
}

struct SettingsView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var selection: SettingsSelection
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

  private var selectedLanguage: AppLanguage {
    AppLanguage(rawValue: language) ?? .system
  }

  var body: some View {
    HStack(spacing: 0) {
      SettingsSidebarView(selection: $selection.pane)
        .frame(width: SettingsLayout.sidebarWidth)
        .background {
          SettingsSidebarMaterial()
            .ignoresSafeArea()
        }

      Divider()
        .ignoresSafeArea()

      detailView
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(
      minWidth: SettingsLayout.windowMinWidth,
      idealWidth: SettingsLayout.windowDefaultWidth,
      maxWidth: .infinity,
      minHeight: SettingsLayout.windowMinHeight,
      idealHeight: SettingsLayout.windowDefaultHeight,
      maxHeight: .infinity
    )
    .background {
      SettingsWindowTitleBridge(
        title: AppLocalization.string(selection.pane.titleKey, language: selectedLanguage)
      )
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var detailView: some View {
    switch selection.pane {
    case .dashboard:
      ContentView(store: store)
    case .settings:
      SettingsPageView()
    case .about:
      AboutView()
    }
  }
}

private struct SettingsSidebarView: View {
  @Binding var selection: SettingsPane

  var body: some View {
    List(selection: selectionBinding) {
      ForEach(SettingsPane.allCases, id: \.self) { pane in
        HStack(spacing: 9) {
          if pane == .about {
            ApplicationIcon(size: 22, fallbackSystemImage: SettingsPane.about.systemImage)
          } else {
            Image(systemName: pane.systemImage)
              .frame(width: 22)
              .foregroundStyle(.secondary)
          }

          Text(LocalizedStringKey(pane.titleKey))
        }
        .tag(pane)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  private var selectionBinding: Binding<SettingsPane?> {
    Binding(
      get: { selection },
      set: { newValue in
        if let newValue {
          selection = newValue
        }
      }
    )
  }
}

private struct SettingsPageView: View {
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
  }
}

private struct SettingsSidebarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
  }
}

private struct SettingsWindowTitleBridge: NSViewRepresentable {
  let title: String

  func makeNSView(context: Context) -> SettingsWindowTitleView {
    let view = SettingsWindowTitleView()
    view.title = title
    return view
  }

  func updateNSView(_ nsView: SettingsWindowTitleView, context: Context) {
    nsView.title = title
  }
}

private final class SettingsWindowTitleView: NSView {
  var title = "" {
    didSet {
      applyTitle()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyTitle()
  }

  private func applyTitle() {
    window?.title = title
  }
}
