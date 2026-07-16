import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    UNUserNotificationCenter.current().delegate = self

    DispatchQueue.main.async {
      NSApp.windows.first { $0.title == "Codex Radar" }?.orderOut(nil)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

@main
struct CodexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore()
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  private var selectedLocale: Locale {
    AppLanguage(rawValue: language)?.locale ?? .current
  }

  private var preferredColorScheme: ColorScheme? {
    AppAppearance.resolve(appearance).colorScheme
  }

  @ViewBuilder
  private var dashboardContent: some View {
    ContentView(store: store)
      .environment(\.locale, selectedLocale)
      .preferredColorScheme(preferredColorScheme)
  }

  var body: some Scene {
    Window("Codex Radar", id: "dashboard") {
      dashboardContent
    }
    .defaultSize(width: 880, height: 760)
    .windowResizability(.contentMinSize)

    MenuBarExtra {
      MenuBarView(store: store)
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
      SettingsView()
        .environment(\.locale, selectedLocale)
        .preferredColorScheme(preferredColorScheme)
    }
  }
}
