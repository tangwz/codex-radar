import Combine

enum SettingsPane: String, CaseIterable, Hashable {
  case dashboard
  case settings
  case about

  var titleKey: String {
    switch self {
    case .dashboard: "Dashboard"
    case .settings: "Settings"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .dashboard: "chart.xyaxis.line"
    case .settings: "gearshape.fill"
    case .about: "info.circle.fill"
    }
  }
}

@MainActor
final class SettingsSelection: ObservableObject {
  @Published var pane: SettingsPane

  init(pane: SettingsPane = .settings) {
    self.pane = pane
  }

  func show(_ pane: SettingsPane) {
    self.pane = pane
  }
}
