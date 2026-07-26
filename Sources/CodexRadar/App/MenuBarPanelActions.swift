import Foundation

@MainActor
struct MenuBarPanelActions {
  enum Failure: Equatable {
    case openSource(URL)
    case openSettings(SettingsPane)
  }

  private let dismissPanel: () -> Void
  private let openURL: (URL) -> Bool
  private let selectSettingsPane: (SettingsPane) -> Void
  private let activateApplication: () -> Void
  private let openSettingsWindow: () -> Bool
  private let terminateApplication: () -> Void
  private let reportFailure: (Failure) -> Void

  init(
    dismissPanel: @escaping () -> Void,
    openURL: @escaping (URL) -> Bool,
    selectSettingsPane: @escaping (SettingsPane) -> Void,
    activateApplication: @escaping () -> Void,
    openSettingsWindow: @escaping () -> Bool,
    terminateApplication: @escaping () -> Void,
    reportFailure: @escaping (Failure) -> Void
  ) {
    self.dismissPanel = dismissPanel
    self.openURL = openURL
    self.selectSettingsPane = selectSettingsPane
    self.activateApplication = activateApplication
    self.openSettingsWindow = openSettingsWindow
    self.terminateApplication = terminateApplication
    self.reportFailure = reportFailure
  }

  func openSource(_ url: URL) {
    dismissPanel()
    if !openURL(url) {
      reportFailure(.openSource(url))
    }
  }

  func openSettings(_ pane: SettingsPane) {
    dismissPanel()
    selectSettingsPane(pane)
    activateApplication()
    if !openSettingsWindow() {
      reportFailure(.openSettings(pane))
    }
  }

  func quit() {
    dismissPanel()
    terminateApplication()
  }
}
