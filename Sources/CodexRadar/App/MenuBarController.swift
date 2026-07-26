import AppKit
import Combine
import OSLog
import SwiftUI

enum MenuBarPanelCommand: Equatable {
  case show
  case dismiss

  static func resolve(isShown: Bool) -> Self {
    isShown ? .dismiss : .show
  }
}

enum MenuBarStatusIconRenderer {
  static let alertDiameter: CGFloat = 6

  @MainActor
  static func image(hasResetAlert: Bool) -> NSImage {
    let base = MenuBarIconConfiguration.image
    base.isTemplate = false
    guard hasResetAlert else { return base }

    let size = NSSize(
      width: MenuBarIconConfiguration.sideLength,
      height: MenuBarIconConfiguration.sideLength
    )
    let image = NSImage(size: size, flipped: false) { rect in
      base.draw(in: rect)
      NSColor.systemRed.setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: rect.maxX - alertDiameter,
          y: rect.maxY - alertDiameter,
          width: alertDiameter,
          height: alertDiameter
        )
      ).fill()
      return true
    }
    image.isTemplate = false
    return image
  }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
  @MainActor
  struct Dependencies {
    let makeStatusItem: @MainActor () -> NSStatusItem
    let removeStatusItem: @MainActor (NSStatusItem) -> Void
    let makePopover: @MainActor () -> NSPopover

    static let live = Self(
      makeStatusItem: {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      },
      removeStatusItem: {
        NSStatusBar.system.removeStatusItem($0)
      },
      makePopover: {
        NSPopover()
      }
    )
  }

  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "menu-bar"
  )

  private let store: DashboardStore
  private let rootView: AnyView
  private let dependencies: Dependencies
  private var popover: NSPopover?
  private var forecastCancellable: AnyCancellable?
  private var defaultsCancellable: AnyCancellable?
  private var lastHasResetAlert: Bool?

  private(set) var statusItem: NSStatusItem?
  private(set) var secondaryClickRecognizer: NSClickGestureRecognizer?

  init(
    store: DashboardStore,
    rootView: AnyView,
    dependencies: Dependencies = .live
  ) {
    self.store = store
    self.rootView = rootView
    self.dependencies = dependencies
    super.init()
  }

  func install() {
    guard statusItem == nil else { return }

    let item = dependencies.makeStatusItem()
    guard let button = item.button else {
      dependencies.removeStatusItem(item)
      Self.logger.error("Failed to create the menu bar status button")
      return
    }

    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = [.preferredContentSize]

    let popover = dependencies.makePopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentViewController = hostingController

    button.imageScaling = .scaleProportionallyDown
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(handleStatusItemClick(_:))

    let secondaryClickRecognizer = NSClickGestureRecognizer(
      target: self,
      action: #selector(handleStatusItemClick(_:))
    )
    secondaryClickRecognizer.buttonMask = 0x2
    button.addGestureRecognizer(secondaryClickRecognizer)

    statusItem = item
    self.popover = popover
    self.secondaryClickRecognizer = secondaryClickRecognizer
    observePresentationState()
    refreshStatusItem()
  }

  func togglePanel() {
    guard let button = statusItem?.button, let popover else { return }

    switch MenuBarPanelCommand.resolve(isShown: popover.isShown) {
    case .show:
      NSApp.activate(ignoringOtherApps: true)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      button.highlight(true)
    case .dismiss:
      dismissPanel()
    }
  }

  func dismissPanel() {
    guard let popover else { return }
    if popover.isShown {
      popover.close()
    } else {
      statusItem?.button?.highlight(false)
    }
  }

  func uninstall() {
    forecastCancellable?.cancel()
    defaultsCancellable?.cancel()
    forecastCancellable = nil
    defaultsCancellable = nil

    popover?.delegate = nil
    popover?.close()
    popover = nil

    if let button = statusItem?.button {
      button.target = nil
      button.action = nil
      if let secondaryClickRecognizer {
        button.removeGestureRecognizer(secondaryClickRecognizer)
      }
    }
    secondaryClickRecognizer = nil

    if let statusItem {
      dependencies.removeStatusItem(statusItem)
      self.statusItem = nil
    }
    lastHasResetAlert = nil
  }

  func popoverDidClose(_ notification: Notification) {
    statusItem?.button?.highlight(false)
  }

  @objc
  private func handleStatusItemClick(_ sender: Any?) {
    togglePanel()
  }

  private func observePresentationState() {
    forecastCancellable = store.$forecast.sink { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshStatusItem()
      }
    }
    defaultsCancellable = NotificationCenter.default.publisher(
      for: UserDefaults.didChangeNotification
    ).sink { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshStatusItem()
      }
    }
  }

  private func refreshStatusItem() {
    guard let button = statusItem?.button else { return }

    let hasResetAlert = ResetForecastPresentation(forecast: store.forecast).hasResetAlert
    if lastHasResetAlert != hasResetAlert {
      button.image = MenuBarStatusIconRenderer.image(hasResetAlert: hasResetAlert)
      lastHasResetAlert = hasResetAlert
    }

    let accessibilityKey =
      hasResetAlert
      ? "Codex reset incoming"
      : "Codex reset monitoring"
    button.setAccessibilityTitle(AppLocalization.string(accessibilityKey))
  }
}
