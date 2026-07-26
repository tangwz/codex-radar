import AppKit
import SwiftUI
import Testing

@testable import CodexRadar

@MainActor
@Suite(.serialized)
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
    let expectedActionMask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]
    let installedActionMask = button.sendAction(on: expectedActionMask)
    button.sendAction(
      on: NSEvent.EventTypeMask(rawValue: UInt64(installedActionMask))
    )
    #expect(created == 1)
    #expect(button.target === controller)
    #expect(installedActionMask == Int(expectedActionMask.rawValue))

    controller.uninstall()
    controller.uninstall()

    #expect(removed == 1)
  }

  @Test
  func installsWithLocalizedAccessibilityLabel() throws {
    _ = NSApplication.shared
    let defaults = UserDefaults.standard
    let previousLanguage = defaults.object(forKey: AppLanguage.defaultsKey)
    defer { restoreLanguage(previousLanguage) }
    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
    let controller = MenuBarController(
      store: makeStore(),
      rootView: AnyView(EmptyView())
    )
    defer { controller.uninstall() }

    controller.install()

    let button = try #require(controller.statusItem?.button)
    #expect(button.accessibilityLabel() == "Codex reset monitoring")
  }

  @Test
  func togglesPopoverAndSynchronizesButtonHighlight() throws {
    _ = NSApplication.shared
    let popover = TestPopover()
    let controller = makeController(popover: popover)
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)

    controller.togglePanel()

    #expect(popover.isShown)
    #expect(popover.showCount == 1)
    #expect(button.isHighlighted)

    controller.togglePanel()

    #expect(!popover.isShown)
    #expect(popover.closeCount == 1)
    #expect(!button.isHighlighted)
  }

  @Test
  func dismissesOrClearsHighlightFromCurrentPopoverVisibility() throws {
    _ = NSApplication.shared
    let popover = TestPopover()
    let controller = makeController(popover: popover)
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)

    controller.togglePanel()
    controller.dismissPanel()

    #expect(popover.closeCount == 1)
    #expect(!button.isHighlighted)

    button.highlight(true)
    controller.dismissPanel()

    #expect(popover.closeCount == 1)
    #expect(!button.isHighlighted)
  }

  @Test
  func keepsHighlightWhenDelayedCloseArrivesAfterReopen() throws {
    _ = NSApplication.shared
    let popover = TestPopover(deliversCloseNotification: false)
    let controller = makeController(popover: popover)
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)

    controller.togglePanel()
    controller.togglePanel()
    controller.togglePanel()
    controller.popoverDidClose(
      Notification(name: NSPopover.didCloseNotification, object: popover)
    )

    #expect(popover.isShown)
    #expect(button.isHighlighted)
  }

  @Test
  func ignoresCloseNotificationFromDifferentPopover() throws {
    _ = NSApplication.shared
    let popover = TestPopover()
    let controller = makeController(popover: popover)
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)

    controller.togglePanel()
    controller.popoverDidClose(
      Notification(name: NSPopover.didCloseNotification, object: TestPopover())
    )

    #expect(popover.isShown)
    #expect(button.isHighlighted)
  }

  @Test
  func updatesStatusPresentationWhenForecastChanges() async throws {
    _ = NSApplication.shared
    let forecast = resetAlertForecast()
    let store = DashboardStore(
      scanSessions: { [] },
      fetchForecast: { _ in .updated(forecast, etag: nil) },
      prepareNotifications: {},
      observeForecast: { _ in },
      formatForecastIssue: { $0 ?? "" },
      pollingSchedule: ResetPollingSchedule(jitter: { 0 }),
      sleep: { _ in },
      observesWakeEvents: false
    )
    let controller = MenuBarController(
      store: store,
      rootView: AnyView(EmptyView())
    )
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)
    let initialImageData = try #require(button.image?.tiffRepresentation)

    await store.refreshForecast()
    await waitUntil {
      button.accessibilityLabel() == AppLocalization.string("Codex reset incoming")
    }

    #expect(button.accessibilityLabel() == AppLocalization.string("Codex reset incoming"))
    #expect(button.image?.tiffRepresentation != initialImageData)
  }

  @Test
  func updatesAccessibilityLabelWhenDefaultsChange() async throws {
    _ = NSApplication.shared
    let labels = MutableLocalizedString(value: "Monitoring label")
    let dependencies = MenuBarController.Dependencies(
      makeStatusItem: {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      },
      removeStatusItem: {
        NSStatusBar.system.removeStatusItem($0)
      },
      makePopover: NSPopover.init,
      localizedString: { _ in labels.value }
    )
    let controller = MenuBarController(
      store: makeStore(),
      rootView: AnyView(EmptyView()),
      dependencies: dependencies
    )
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)
    #expect(button.accessibilityLabel() == "Monitoring label")

    labels.value = "Updated monitoring label"
    NotificationCenter.default.post(
      name: UserDefaults.didChangeNotification,
      object: UserDefaults.standard
    )
    await waitUntil {
      button.accessibilityLabel() == "Updated monitoring label"
    }

    #expect(button.accessibilityLabel() == "Updated monitoring label")
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

@MainActor
private func makeController(popover: NSPopover) -> MenuBarController {
  MenuBarController(
    store: makeStore(),
    rootView: AnyView(EmptyView()),
    dependencies: MenuBarController.Dependencies(
      makeStatusItem: {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      },
      removeStatusItem: {
        NSStatusBar.system.removeStatusItem($0)
      },
      makePopover: { popover }
    )
  )
}

@MainActor
private func restoreLanguage(_ value: Any?) {
  let defaults = UserDefaults.standard
  if let value {
    defaults.set(value, forKey: AppLanguage.defaultsKey)
  } else {
    defaults.removeObject(forKey: AppLanguage.defaultsKey)
  }
}

@MainActor
private func waitUntil(
  _ condition: @escaping @MainActor () -> Bool
) async {
  for _ in 0..<40 where !condition() {
    await Task.yield()
  }
}

private func resetAlertForecast() -> ResetForecast {
  ResetForecast(
    schemaVersion: "1.0",
    monitoredAt: Date(timeIntervalSince1970: 1_700_000_000),
    stale: false,
    status: .announced,
    recommendedAction: .wait,
    message: "Reset announced.",
    signalID: "signal-1",
    timing: ResetTiming(kind: .imminent),
    sourceURL: nil,
    posts: []
  )
}

@MainActor
private final class TestPopover: NSPopover {
  private var testIsShown = false
  private let deliversCloseNotification: Bool
  private(set) var showCount = 0
  private(set) var closeCount = 0

  init(deliversCloseNotification: Bool = true) {
    self.deliversCloseNotification = deliversCloseNotification
    super.init()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isShown: Bool {
    testIsShown
  }

  override func show(
    relativeTo positioningRect: NSRect,
    of positioningView: NSView,
    preferredEdge: NSRectEdge
  ) {
    testIsShown = true
    showCount += 1
  }

  override func close() {
    guard testIsShown else { return }
    testIsShown = false
    closeCount += 1
    guard deliversCloseNotification else { return }

    delegate?.popoverDidClose?(
      Notification(name: NSPopover.didCloseNotification, object: self)
    )
  }
}

@MainActor
private final class MutableLocalizedString {
  var value: String

  init(value: String) {
    self.value = value
  }
}
