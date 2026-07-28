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
  func activatesApplicationBeforeShowingPanel() throws {
    var events: [String] = []
    let popover = TestPopover(
      onShow: {
        events.append("showPopover")
      }
    )
    let controller = MenuBarController(
      store: makeStore(),
      rootView: AnyView(EmptyView()),
      dependencies: MenuBarController.Dependencies(
        makeStatusItem: TestStatusItem.init,
        removeStatusItem: { _ in },
        makePopover: { popover },
        activateApplication: {
          events.append("activateApplication")
        }
      )
    )
    defer { controller.uninstall() }
    controller.install()

    controller.togglePanel()

    #expect(events == ["activateApplication", "showPopover"])
    #expect(popover.isShown)
  }

  @Test
  func installsOnePassiveResetAlertBadge() throws {
    let controller = MenuBarController(
      store: makeStore(),
      rootView: AnyView(EmptyView()),
      dependencies: makeDependencies()
    )
    defer { controller.uninstall() }

    controller.install()
    controller.install()

    let button = try #require(controller.statusItem?.button)
    let badge = try #require(controller.resetAlertBadgeView)
    #expect(button.image === MenuBarIconConfiguration.image)
    #expect(
      button.subviews.filter { $0 is MenuBarResetAlertBadgeView }.count == 1
    )
    #expect(badge.superview === button)
    #expect(badge.isHidden)
    #expect(badge.hitTest(NSPoint(x: 1, y: 1)) == nil)
  }

  @Test
  func updatesResetAlertBadgeColorWhenAppearanceChanges() throws {
    let aquaAppearance = try #require(NSAppearance(named: .aqua))
    let darkAquaAppearance = try #require(NSAppearance(named: .darkAqua))
    let badge = MenuBarResetAlertBadgeView()

    badge.appearance = aquaAppearance
    badge.needsDisplay = true
    badge.displayIfNeeded()
    let aquaColor = try #require(badge.layer?.backgroundColor)
    #expect(aquaColor == systemRedColor(for: aquaAppearance))

    badge.needsDisplay = false
    badge.appearance = darkAquaAppearance
    badge.displayIfNeeded()
    let darkAquaColor = try #require(badge.layer?.backgroundColor)
    #expect(darkAquaColor == systemRedColor(for: darkAquaAppearance))
    #expect(darkAquaColor != aquaColor)
  }

  @Test
  func installsOnlyOnceAndRemovesOnlyOnce() throws {
    var created = 0
    var removed = 0
    let dependencies = MenuBarController.Dependencies(
      makeStatusItem: {
        created += 1
        return TestStatusItem()
      },
      removeStatusItem: { _ in
        removed += 1
      },
      makePopover: NSPopover.init,
      activateApplication: {}
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
    let defaults = UserDefaults.standard
    let previousLanguage = defaults.object(forKey: AppLanguage.defaultsKey)
    defer { restoreLanguage(previousLanguage) }
    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
    let controller = MenuBarController(
      store: makeStore(),
      rootView: AnyView(EmptyView()),
      dependencies: makeDependencies()
    )
    defer { controller.uninstall() }

    controller.install()

    let button = try #require(controller.statusItem?.button)
    #expect(button.accessibilityLabel() == "Codex reset monitoring")
  }

  @Test
  func togglesPopoverAndSynchronizesButtonHighlight() throws {
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
    let forecast = resetAlertForecast()
    let store = DashboardStore(
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
      rootView: AnyView(EmptyView()),
      dependencies: makeDependencies()
    )
    defer { controller.uninstall() }
    controller.install()
    let button = try #require(controller.statusItem?.button)
    let initialImage = try #require(button.image)
    let badge = try #require(controller.resetAlertBadgeView)
    #expect(badge.isHidden)

    await store.refreshForecast()
    await waitUntil {
      button.accessibilityLabel() == AppLocalization.string("Codex reset incoming")
    }

    #expect(button.accessibilityLabel() == AppLocalization.string("Codex reset incoming"))
    #expect(button.image === initialImage)
    #expect(badge.isHidden == false)
  }

  @Test
  func updatesAccessibilityLabelWhenDefaultsChange() async throws {
    let labels = MutableLocalizedString(value: "Monitoring label")
    let dependencies = MenuBarController.Dependencies(
      makeStatusItem: TestStatusItem.init,
      removeStatusItem: { _ in },
      makePopover: NSPopover.init,
      activateApplication: {},
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

private func systemRedColor(for appearance: NSAppearance) -> CGColor {
  var color = NSColor.clear.cgColor
  appearance.performAsCurrentDrawingAppearance {
    color = NSColor.systemRed.cgColor
  }
  return color
}

@MainActor
private func makeStore() -> DashboardStore {
  DashboardStore(
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
    dependencies: makeDependencies(popover: popover)
  )
}

@MainActor
private func makeDependencies(
  popover: NSPopover = NSPopover()
) -> MenuBarController.Dependencies {
  MenuBarController.Dependencies(
    makeStatusItem: TestStatusItem.init,
    removeStatusItem: { _ in },
    makePopover: { popover },
    activateApplication: {}
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
  private let onShow: @MainActor () -> Void
  private(set) var showCount = 0
  private(set) var closeCount = 0

  init(
    deliversCloseNotification: Bool = true,
    onShow: @escaping @MainActor () -> Void = {}
  ) {
    self.deliversCloseNotification = deliversCloseNotification
    self.onShow = onShow
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
    onShow()
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

@MainActor
private final class TestStatusItem: NSStatusItem {
  private let testButton = NSStatusBarButton(frame: .zero)

  override var button: NSStatusBarButton? {
    testButton
  }
}
