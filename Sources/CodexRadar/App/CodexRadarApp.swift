import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  @MainActor
  let updaterSettings = UpdaterSettingsModel(provider: UpdaterFactory.make(bundle: .main))

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    UNUserNotificationCenter.current().delegate = self
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
    guard UpdateReminderNotification.isDefaultAction(
      identifier: response.notification.request.identifier,
      actionIdentifier: response.actionIdentifier
    ) else {
      return
    }

    await updaterSettings.showUpdateFromReminder()
  }
}

@main
struct CodexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore()
  @StateObject private var settingsSelection = SettingsSelection()
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  private var selectedLocale: Locale {
    AppLanguage(rawValue: language)?.locale ?? .current
  }

  private var preferredColorScheme: ColorScheme? {
    AppAppearance.resolve(appearance).colorScheme
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(store: store, settingsSelection: settingsSelection)
        .environment(\.locale, selectedLocale)
        .preferredColorScheme(preferredColorScheme)
    } label: {
      MenuBarLabel(
        hasResetAlert: ResetForecastPresentation(forecast: store.forecast).hasResetAlert
      )
        .environment(\.locale, selectedLocale)
        .preferredColorScheme(preferredColorScheme)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(
        store: store,
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
