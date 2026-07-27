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

@MainActor
final class MenuBarResetAlertBadgeView: NSView {
  static let diameter: CGFloat = 6

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = Self.diameter / 2
    isHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var wantsUpdateLayer: Bool {
    true
  }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.systemRed.cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
  @MainActor
  struct Dependencies {
    let makeStatusItem: @MainActor () -> NSStatusItem
    let removeStatusItem: @MainActor (NSStatusItem) -> Void
    let makePopover: @MainActor () -> NSPopover
    let activateApplication: @MainActor () -> Void
    let localizedString: @MainActor (String) -> String

    init(
      makeStatusItem: @escaping @MainActor () -> NSStatusItem,
      removeStatusItem: @escaping @MainActor (NSStatusItem) -> Void,
      makePopover: @escaping @MainActor () -> NSPopover,
      activateApplication: @escaping @MainActor () -> Void,
      localizedString: @escaping @MainActor (String) -> String = {
        AppLocalization.string($0)
      }
    ) {
      self.makeStatusItem = makeStatusItem
      self.removeStatusItem = removeStatusItem
      self.makePopover = makePopover
      self.activateApplication = activateApplication
      self.localizedString = localizedString
    }

    static let live = Self(
      makeStatusItem: {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      },
      removeStatusItem: {
        NSStatusBar.system.removeStatusItem($0)
      },
      makePopover: {
        NSPopover()
      },
      activateApplication: {
        NSApp.activate(ignoringOtherApps: true)
      },
      localizedString: {
        AppLocalization.string($0)
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
  private(set) var resetAlertBadgeView: MenuBarResetAlertBadgeView?

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

    button.image = MenuBarIconConfiguration.image
    button.imageScaling = .scaleProportionallyDown
    button.imagePosition = .imageOnly
    button.target = self
    button.action = #selector(handleStatusItemClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    let resetAlertBadgeView = MenuBarResetAlertBadgeView()
    button.addSubview(resetAlertBadgeView)
    NSLayoutConstraint.activate([
      resetAlertBadgeView.widthAnchor.constraint(
        equalToConstant: MenuBarResetAlertBadgeView.diameter
      ),
      resetAlertBadgeView.heightAnchor.constraint(
        equalToConstant: MenuBarResetAlertBadgeView.diameter
      ),
      resetAlertBadgeView.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
      resetAlertBadgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
    ])

    statusItem = item
    self.resetAlertBadgeView = resetAlertBadgeView
    self.popover = popover
    observePresentationState()
    refreshStatusItem()
  }

  func togglePanel() {
    guard let button = statusItem?.button, let popover else { return }

    switch MenuBarPanelCommand.resolve(isShown: popover.isShown) {
    case .show:
      dependencies.activateApplication()
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
    }

    resetAlertBadgeView?.removeFromSuperview()
    resetAlertBadgeView = nil

    if let statusItem {
      dependencies.removeStatusItem(statusItem)
      self.statusItem = nil
    }
    lastHasResetAlert = nil
  }

  func popoverDidClose(_ notification: Notification) {
    guard notification.object as? NSPopover === popover, popover?.isShown == false else {
      return
    }
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
    guard
      let button = statusItem?.button,
      let resetAlertBadgeView
    else {
      return
    }

    let hasResetAlert = ResetForecastPresentation(forecast: store.forecast).hasResetAlert
    if lastHasResetAlert != hasResetAlert {
      resetAlertBadgeView.isHidden = !hasResetAlert
      lastHasResetAlert = hasResetAlert
    }

    let accessibilityKey =
      hasResetAlert
      ? "Codex reset incoming"
      : "Codex reset monitoring"
    button.setAccessibilityLabel(dependencies.localizedString(accessibilityKey))
  }
}
