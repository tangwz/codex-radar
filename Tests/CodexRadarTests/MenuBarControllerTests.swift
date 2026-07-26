import AppKit
import SwiftUI
import Testing

@testable import CodexRadar

@MainActor
struct MenuBarControllerTests {
  @Test
  func resolvesOneToggleCommandFromPopoverVisibility() {
    #expect(MenuBarPanelCommand.resolve(isShown: false) == .show)
    #expect(MenuBarPanelCommand.resolve(isShown: true) == .dismiss)
  }

  @Test
  func rendersStableNormalAndAlertStatusImages() throws {
    let normal = MenuBarStatusIconRenderer.image(hasResetAlert: false)
    let alert = MenuBarStatusIconRenderer.image(hasResetAlert: true)
    let normalData = try #require(normal.tiffRepresentation)
    let alertData = try #require(alert.tiffRepresentation)

    #expect(normal.size == NSSize(width: 18, height: 18))
    #expect(alert.size == normal.size)
    #expect(normalData != alertData)
  }

  @Test
  func installsOnlyOnceAndRemovesOnlyOnce() throws {
    _ = NSApplication.shared
    var created = 0
    var removed = 0
    let dependencies = MenuBarController.Dependencies(
      makeStatusItem: {
        created += 1
        return NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      },
      removeStatusItem: {
        removed += 1
        NSStatusBar.system.removeStatusItem($0)
      },
      makePopover: NSPopover.init
    )
    let controller = MenuBarController(
      store: makeStore(),
      rootView: AnyView(EmptyView()),
      dependencies: dependencies
    )
    defer { controller.uninstall() }

    controller.install()
    controller.install()

    let button = try #require(controller.statusItem?.button)
    let secondaryClickRecognizer = try #require(controller.secondaryClickRecognizer)
    #expect(created == 1)
    #expect(button.target === controller)
    #expect(secondaryClickRecognizer.buttonMask == 0x2)
    #expect(button.action == secondaryClickRecognizer.action)
    #expect(
      button.gestureRecognizers.contains {
        $0 === secondaryClickRecognizer
      }
    )

    controller.uninstall()
    controller.uninstall()

    #expect(removed == 1)
  }
}

@MainActor
private func makeStore() -> DashboardStore {
  DashboardStore(
    scanSessions: { [] },
    fetchForecast: { _ in .notModified },
    prepareNotifications: {},
    observeForecast: { _ in },
    formatForecastIssue: { $0 ?? "" },
    pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
    sleep: { _ in },
    observesWakeEvents: false
  )
}
