import AppKit
import OSLog
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private struct Configuration {
    let store: DashboardStore
    let historyStore: ResetHistoryStore
    let settingsSelection: SettingsSelection
  }

  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "app"
  )

  @MainActor
  let updaterSettings = UpdaterSettingsModel(provider: UpdaterFactory.make(bundle: .main))

  @MainActor
  private var configuration: Configuration?
  @MainActor
  private var menuBarController: MenuBarController?
  @MainActor
  private var didFinishLaunching = false

  @MainActor
  func configure(
    store: DashboardStore,
    historyStore: ResetHistoryStore,
    settingsSelection: SettingsSelection
  ) {
    configuration = Configuration(
      store: store,
      historyStore: historyStore,
      settingsSelection: settingsSelection
    )
    installMenuBarIfReady()
  }

  @MainActor
  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    NSApp.setActivationPolicy(.accessory)
    UNUserNotificationCenter.current().delegate = self
    installMenuBarIfReady()
  }

  @MainActor
  func applicationWillTerminate(_ notification: Notification) {
    menuBarController?.uninstall()
    menuBarController = nil
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard
      UpdateReminderNotification.isDefaultAction(
        identifier: response.notification.request.identifier,
        actionIdentifier: response.actionIdentifier
      )
    else {
      return
    }

    await updaterSettings.showUpdateFromReminder()
  }

  @MainActor
  private func installMenuBarIfReady() {
    guard didFinishLaunching,
      menuBarController == nil,
      let configuration
    else {
      return
    }

    let actions = MenuBarPanelActions(
      dismissPanel: { [weak self] in
        self?.menuBarController?.dismissPanel()
      },
      openURL: {
        NSWorkspace.shared.open($0)
      },
      selectSettingsPane: {
        configuration.settingsSelection.show($0)
      },
      activateApplication: {
        NSApp.activate(ignoringOtherApps: true)
      },
      openSettingsWindow: {
        SettingsWindowOpener.live().open(preferred: .notification)
      },
      terminateApplication: {
        NSApp.terminate(nil)
      },
      reportFailure: {
        Self.logPanelActionFailure($0)
      }
    )

    let controller = MenuBarController(
      store: configuration.store,
      rootView: AnyView(
        MenuBarPanelRootView(
          store: configuration.store,
          historyStore: configuration.historyStore,
          actions: actions
        )
      )
    )
    menuBarController = controller
    controller.install()
  }

  @MainActor
  private static func logPanelActionFailure(_ failure: MenuBarPanelActions.Failure) {
    switch failure {
    case .openSource(let url):
      logger.error("Failed to open source URL: \(url.absoluteString, privacy: .public)")
    case .openSettings(let pane):
      logger.error("Failed to open Settings pane: \(pane.rawValue, privacy: .public)")
    }
  }
}

@main
struct CodexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store: DashboardStore
  @StateObject private var historyStore: ResetHistoryStore
  @StateObject private var settingsSelection: SettingsSelection
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  init() {
    let store = DashboardStore()
    let historyStore = ResetHistoryStore()
    let settingsSelection = SettingsSelection()
    _store = StateObject(wrappedValue: store)
    _historyStore = StateObject(wrappedValue: historyStore)
    _settingsSelection = StateObject(wrappedValue: settingsSelection)
    appDelegate.configure(
      store: store,
      historyStore: historyStore,
      settingsSelection: settingsSelection
    )
  }

  private var selectedLocale: Locale {
    AppLanguage(rawValue: language)?.locale ?? .current
  }

  private var preferredColorScheme: ColorScheme? {
    AppAppearance.resolve(appearance).colorScheme
  }

  var body: some Scene {
    Window("CodexRadarLifecycleKeepalive", id: "lifecycle-keepalive") {
      SettingsOpenBridgeView()
    }
    .defaultSize(width: 20, height: 20)
    .windowStyle(.hiddenTitleBar)

    Settings {
      SettingsView(
        store: store,
        historyStore: historyStore,
        selection: settingsSelection,
        updaterSettings: appDelegate.updaterSettings
      )
      .environment(\.locale, selectedLocale)
      .preferredColorScheme(preferredColorScheme)
    }
    .defaultSize(width: 1000, height: 720)
    .windowResizability(.contentMinSize)
  }
}
