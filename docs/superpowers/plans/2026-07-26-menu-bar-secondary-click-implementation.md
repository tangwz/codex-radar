# Menu Bar Secondary Click Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SwiftUI `MenuBarExtra` entry with a narrowly scoped `NSStatusItem + NSPopover` bridge so left-click, right-click, and Control-left-click toggle the same Menu Bar Panel.

**Architecture:** Keep `DashboardStore` and the SwiftUI panel as the only owners of business and view state. Add a small AppKit presentation adapter for the status item and popover, compose external panel actions at the application boundary, and relay Settings requests back into SwiftUI through a hidden lifecycle scene.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSStatusItem`, `NSPopover`, `NSHostingController`), Combine, OSLog, Swift Testing, SwiftPM, macOS 14+

**Design Spec:** `docs/superpowers/specs/2026-07-26-menu-bar-secondary-click-design.md`

**Verified Baseline:** `swift test` passes 95 tests in 20 suites before implementation. Tasks 1-4 add 11 tests, so the final suite should pass 106 tests.

## Global Constraints

- Keep the deployment floor at macOS 14.
- Left-click, right-click, and Control-left-click use one toggle path: closed becomes open and open becomes closed.
- Do not add a right-click context menu.
- Preserve the existing 300pt SwiftUI Menu Bar Panel content, theme, localization, shortcuts, reset alert, and business behavior.
- Keep `DashboardStore`, `SettingsSelection`, and `AppStorage` as the only writable sources for their existing state.
- Keep `MenuBarController` limited to AppKit presentation, status-icon presentation, and lifecycle.
- Dismiss the popover before Source URL, Dashboard, Settings, About, and Quit side effects; Refresh keeps the popover open.
- Do not use global event monitors, private APIs, or SwiftUI view-hierarchy probing.
- Do not introduce new package dependencies.
- All code, identifiers, comments, commit messages, and code blocks remain English.

---

### Task 1: Define and test ordered panel actions

**Files:**
- Create: `Sources/CodexRadar/App/MenuBarPanelActions.swift`
- Create: `Tests/CodexRadarTests/MenuBarPanelActionsTests.swift`

**Interfaces:**
- Consumes: Existing `SettingsPane`.
- Produces: `MenuBarPanelActions.init(dismissPanel:openURL:selectSettingsPane:activateApplication:openSettingsWindow:terminateApplication:reportFailure:)`, `openSource(_:)`, `openSettings(_:)`, `quit()`, and `MenuBarPanelActions.Failure`.

- [ ] **Step 1: Write failing ordering and failure tests**

Create `Tests/CodexRadarTests/MenuBarPanelActionsTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexRadar

@MainActor
struct MenuBarPanelActionsTests {
  private enum Event: Equatable {
    case dismiss
    case openURL(URL)
    case select(SettingsPane)
    case activate
    case openSettingsWindow
    case terminate
    case failure(MenuBarPanelActions.Failure)
  }

  private final class Recorder {
    var events: [Event] = []
  }

  @Test
  func dismissesBeforeOpeningSource() {
    let url = URL(string: "https://example.com/source")!
    let recorder = Recorder()
    let actions = makeActions(recorder: recorder)

    actions.openSource(url)

    #expect(recorder.events == [.dismiss, .openURL(url)])
  }

  @Test
  func dismissesBeforeSelectingAndOpeningEverySettingsPane() {
    let recorder = Recorder()
    let actions = makeActions(recorder: recorder)

    for pane in SettingsPane.allCases {
      recorder.events.removeAll()
      actions.openSettings(pane)

      #expect(
        recorder.events
          == [
            .dismiss,
            .select(pane),
            .activate,
            .openSettingsWindow,
          ]
      )
    }
  }

  @Test
  func dismissesBeforeTermination() {
    let recorder = Recorder()
    let actions = makeActions(recorder: recorder)

    actions.quit()

    #expect(recorder.events == [.dismiss, .terminate])
  }

  @Test
  func reportsFailedRoutesWithoutReopeningThePanel() {
    let url = URL(string: "https://example.com/failure")!
    let recorder = Recorder()
    let actions = MenuBarPanelActions(
      dismissPanel: { recorder.events.append(.dismiss) },
      openURL: {
        recorder.events.append(.openURL($0))
        return false
      },
      selectSettingsPane: { recorder.events.append(.select($0)) },
      activateApplication: { recorder.events.append(.activate) },
      openSettingsWindow: {
        recorder.events.append(.openSettingsWindow)
        return false
      },
      terminateApplication: { recorder.events.append(.terminate) },
      reportFailure: { recorder.events.append(.failure($0)) }
    )

    actions.openSource(url)
    #expect(
      recorder.events
        == [.dismiss, .openURL(url), .failure(.openSource(url))]
    )

    recorder.events.removeAll()
    actions.openSettings(.dashboard)
    #expect(
      recorder.events
        == [
          .dismiss,
          .select(.dashboard),
          .activate,
          .openSettingsWindow,
          .failure(.openSettings(.dashboard)),
        ]
    )
  }

  private func makeActions(recorder: Recorder) -> MenuBarPanelActions {
    MenuBarPanelActions(
      dismissPanel: { recorder.events.append(.dismiss) },
      openURL: {
        recorder.events.append(.openURL($0))
        return true
      },
      selectSettingsPane: { recorder.events.append(.select($0)) },
      activateApplication: { recorder.events.append(.activate) },
      openSettingsWindow: {
        recorder.events.append(.openSettingsWindow)
        return true
      },
      terminateApplication: { recorder.events.append(.terminate) },
      reportFailure: { recorder.events.append(.failure($0)) }
    )
  }
}
```

- [ ] **Step 2: Run the new test and verify compilation fails**

Run:

```bash
swift test --filter MenuBarPanelActionsTests
```

Expected: compilation fails because `MenuBarPanelActions` does not exist.

- [ ] **Step 3: Implement the ordered action value**

Create `Sources/CodexRadar/App/MenuBarPanelActions.swift`:

```swift
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
```

- [ ] **Step 4: Run focused tests and format the new files**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/App/MenuBarPanelActions.swift \
  Tests/CodexRadarTests/MenuBarPanelActionsTests.swift
swift test --filter MenuBarPanelActionsTests
```

Expected: four tests pass.

- [ ] **Step 5: Commit the action boundary**

```bash
git add \
  Sources/CodexRadar/App/MenuBarPanelActions.swift \
  Tests/CodexRadarTests/MenuBarPanelActionsTests.swift
git commit -m "feat: add ordered menu bar panel actions"
```

---

### Task 2: Inject panel actions into the SwiftUI content

**Files:**
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift:14-154`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift:156-250`
- Modify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift`

**Interfaces:**
- Consumes: `MenuBarPanelActions` from Task 1, `DashboardStore`, `AppLanguage`, and `AppAppearance`.
- Produces: `MenuBarView.init(store:actions:)`, `MenuBarPanelRootView.init(store:actions:)`, and a source-chip callback that routes through `MenuBarPanelActions.openSource(_:)`.

- [ ] **Step 1: Add a compile-time construction test**

Append to `MenuActionLayoutTests`:

```swift
  @Test
  @MainActor
  func constructsTheMenuBarViewWithInjectedPanelActions() {
    let actions = MenuBarPanelActions(
      dismissPanel: {},
      openURL: { _ in true },
      selectSettingsPane: { _ in },
      activateApplication: {},
      openSettingsWindow: { true },
      terminateApplication: {},
      reportFailure: { _ in }
    )

    _ = MenuBarView(store: DashboardStore(), actions: actions)
    _ = MenuBarPanelRootView(store: DashboardStore(), actions: actions)
  }
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter MenuActionLayoutTests
```

Expected: compilation fails because the new initializers and `MenuBarPanelRootView` do not exist.

- [ ] **Step 3: Replace scene-bound actions with the injected action value**

At the top of `MenuBarView`, replace its stored properties with:

```swift
struct MenuBarView: View {
  @ObservedObject var store: DashboardStore
  let actions: MenuBarPanelActions
  @Environment(\.colorScheme) private var colorScheme
```

Pass the source action into the prediction card:

```swift
      MenuResetPredictionCard(
        forecast: store.forecast,
        isRefreshing: store.isRefreshing,
        theme: theme,
        openSource: actions.openSource
      )
```

Replace the Dashboard, Settings, About, and Quit button actions:

```swift
    case .dashboard:
      Button {
        actions.openSettings(.dashboard)
      } label: {
        MenuActionRow(
          title: "Dashboard",
          systemImage: "rectangle.grid.2x2",
          shortcut: "⌘D",
          theme: theme
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut("d", modifiers: .command)

    case .settings:
      Button {
        actions.openSettings(.settings)
      } label: {
        MenuActionRow(
          title: "Settings",
          systemImage: "gearshape",
          shortcut: "⌘,",
          theme: theme
        )
      }
      .buttonStyle(.plain)
      .keyboardShortcut(",", modifiers: .command)

    case .about:
      Button {
        actions.openSettings(.about)
      } label: {
        MenuActionRow(
          title: "About",
          systemImage: "info.circle",
          theme: theme
        )
      }
      .buttonStyle(.plain)

    case .quit:
      Button {
        actions.quit()
      } label: {
        MenuActionRow(title: "Quit", systemImage: "power", shortcut: "⌘Q", theme: theme)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("q", modifiers: .command)
```

Delete the old `showSettings(_:)` helper and the `@Environment(\.openSettings)` property. Leave Refresh unchanged so it continues to call `DashboardStore.refresh()` without dismissing the panel.

- [ ] **Step 4: Route the source chip through the injected action**

Add the callback to `MenuResetPredictionCard`:

```swift
private struct MenuResetPredictionCard: View {
  let forecast: ResetForecast
  let isRefreshing: Bool
  let theme: MenuBarTheme
  let openSource: (URL) -> Void
  @Environment(\.locale) private var locale
```

Replace the existing `Link` with:

```swift
      if let sourceURL = presentation.sourceURL {
        Button {
          openSource(sourceURL)
        } label: {
          PredictionSourceChip(theme: theme)
        }
        .buttonStyle(.plain)
      }
```

- [ ] **Step 5: Add the environment-owning root wrapper**

Add above `MenuBarView`:

```swift
struct MenuBarPanelRootView: View {
  @ObservedObject var store: DashboardStore
  let actions: MenuBarPanelActions
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  private var selectedLocale: Locale {
    AppLanguage(rawValue: language)?.locale ?? .current
  }

  private var preferredColorScheme: ColorScheme? {
    AppAppearance.resolve(appearance).colorScheme
  }

  var body: some View {
    MenuBarView(store: store, actions: actions)
      .environment(\.locale, selectedLocale)
      .preferredColorScheme(preferredColorScheme)
  }
}
```

- [ ] **Step 6: Format and run the focused suites**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/Views/MenuBarView.swift \
  Tests/CodexRadarTests/MenuActionLayoutTests.swift
swift test --filter MenuActionLayoutTests
swift test --filter MenuBarPanelActionsTests
```

Expected: both focused suites pass; existing action order and icon configuration tests remain green.

- [ ] **Step 7: Commit the SwiftUI action injection**

```bash
git add \
  Sources/CodexRadar/Views/MenuBarView.swift \
  Tests/CodexRadarTests/MenuActionLayoutTests.swift
git commit -m "refactor: inject menu bar panel actions"
```

---

### Task 3: Add a typed Settings scene bridge

**Files:**
- Create: `Sources/CodexRadar/App/SettingsWindowBridge.swift`
- Create: `Tests/CodexRadarTests/SettingsWindowBridgeTests.swift`

**Interfaces:**
- Consumes: SwiftUI `EnvironmentValues.openSettings`, `NSApplication.sendAction`, and `NotificationCenter`.
- Produces: `SettingsWindowOpener.live()`, `SettingsWindowOpener.open(preferred:) -> Bool`, `SettingsOpenBridgeView`, and `KeepaliveWindowConfigurator`.

- [ ] **Step 1: Write opener precedence tests**

Create `Tests/CodexRadarTests/SettingsWindowBridgeTests.swift`:

```swift
import Testing

@testable import CodexRadar

@MainActor
struct SettingsWindowBridgeTests {
  @Test
  func usesThePreferredSettingsPathFirst() {
    var attempts: [SettingsWindowOpener.Path] = []
    let opener = SettingsWindowOpener(
      notification: {
        attempts.append(.notification)
        return true
      },
      appKit: {
        attempts.append(.appKit)
        return true
      }
    )

    #expect(opener.open(preferred: .notification))
    #expect(attempts == [.notification])
  }

  @Test
  func fallsBackWhenThePreferredPathIsUnavailable() {
    var attempts: [SettingsWindowOpener.Path] = []
    let opener = SettingsWindowOpener(
      notification: {
        attempts.append(.notification)
        return true
      },
      appKit: {
        attempts.append(.appKit)
        return false
      }
    )

    #expect(opener.open(preferred: .appKit))
    #expect(attempts == [.appKit, .notification])
  }

  @Test
  func reportsFailureWhenNeitherPathHandlesTheRequest() {
    let opener = SettingsWindowOpener(
      notification: { false },
      appKit: { false }
    )

    #expect(!opener.open(preferred: .notification))
  }
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter SettingsWindowBridgeTests
```

Expected: compilation fails because `SettingsWindowOpener` does not exist.

- [ ] **Step 3: Implement the opener and notification relay**

Create `Sources/CodexRadar/App/SettingsWindowBridge.swift`:

```swift
import AppKit
import SwiftUI

extension Notification.Name {
  static let codexRadarOpenSettings = Notification.Name("CodexRadar.OpenSettings")
}

@MainActor
final class SettingsOpenRequest {
  var wasHandled = false
}

@MainActor
struct SettingsWindowOpener {
  enum Path: Equatable {
    case notification
    case appKit
  }

  private let notification: () -> Bool
  private let appKit: () -> Bool

  init(
    notification: @escaping () -> Bool,
    appKit: @escaping () -> Bool
  ) {
    self.notification = notification
    self.appKit = appKit
  }

  static func live() -> Self {
    Self(
      notification: {
        let request = SettingsOpenRequest()
        NotificationCenter.default.post(name: .codexRadarOpenSettings, object: request)
        return request.wasHandled
      },
      appKit: {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
      }
    )
  }

  func open(preferred: Path) -> Bool {
    let attempts = preferred == .notification
      ? [notification, appKit]
      : [appKit, notification]

    return attempts[0]() || attempts[1]()
  }
}

struct SettingsOpenBridgeView: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Color.clear
      .frame(width: 20, height: 20)
      .background(KeepaliveWindowConfigurator())
      .onReceive(NotificationCenter.default.publisher(for: .codexRadarOpenSettings)) {
        notification in
        (notification.object as? SettingsOpenRequest)?.wasHandled = true
        Task { @MainActor in
          openSettings()
        }
      }
  }
}

@MainActor
struct KeepaliveWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> KeepaliveWindowConfiguratorView {
    KeepaliveWindowConfiguratorView()
  }

  func updateNSView(_ nsView: KeepaliveWindowConfiguratorView, context: Context) {}
}

@MainActor
final class KeepaliveWindowConfiguratorView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }

    window.identifier = NSUserInterfaceItemIdentifier("CodexRadarLifecycleKeepalive")
    window.styleMask = [.borderless]
    window.collectionBehavior = [.auxiliary, .ignoresCycle, .transient, .canJoinAllSpaces]
    window.isExcludedFromWindowsMenu = true
    window.level = .floating
    window.isOpaque = false
    window.alphaValue = 0
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.canHide = false
    window.setContentSize(NSSize(width: 1, height: 1))
    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
  }
}
```

- [ ] **Step 4: Format and run the bridge tests**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/App/SettingsWindowBridge.swift \
  Tests/CodexRadarTests/SettingsWindowBridgeTests.swift
swift test --filter SettingsWindowBridgeTests
```

Expected: all three opener tests pass.

- [ ] **Step 5: Commit the Settings bridge**

```bash
git add \
  Sources/CodexRadar/App/SettingsWindowBridge.swift \
  Tests/CodexRadarTests/SettingsWindowBridgeTests.swift
git commit -m "feat: add settings scene bridge"
```

---

### Task 4: Implement the status item and popover presentation adapter

**Files:**
- Create: `Sources/CodexRadar/App/MenuBarController.swift`
- Create: `Tests/CodexRadarTests/MenuBarControllerTests.swift`

**Interfaces:**
- Consumes: `DashboardStore`, `MenuBarIconConfiguration.image`, `MenuBarPanelRootView` wrapped as `AnyView`, and `AppLocalization`.
- Produces: `MenuBarController.install()`, `togglePanel()`, `dismissPanel()`, `uninstall()`, `MenuBarPanelCommand.resolve(isShown:)`, and `MenuBarStatusIconRenderer.image(hasResetAlert:)`.

- [ ] **Step 1: Write command, icon, and installation tests**

Create `Tests/CodexRadarTests/MenuBarControllerTests.swift`:

```swift
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
      store: DashboardStore(),
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
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter MenuBarControllerTests
```

Expected: compilation fails because the controller, command, and icon renderer do not exist.

- [ ] **Step 3: Implement the presentation command and status image renderer**

Create the beginning of `Sources/CodexRadar/App/MenuBarController.swift`:

```swift
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
```

- [ ] **Step 4: Implement the controller lifecycle and click wiring**

Append to `MenuBarController.swift`:

```swift
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

    let accessibilityKey = hasResetAlert
      ? "Codex reset incoming"
      : "Codex reset monitoring"
    button.setAccessibilityTitle(AppLocalization.string(accessibilityKey))
  }
}
```

The status button target-action handles ordinary primary clicks. The secondary recognizer handles both physical right-clicks and macOS Control-left-click translation. Both paths call the same selector, so they cannot accumulate separate presentation behavior.

- [ ] **Step 5: Format and run the controller tests**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/App/MenuBarController.swift \
  Tests/CodexRadarTests/MenuBarControllerTests.swift
swift test --filter MenuBarControllerTests
```

Expected: all three tests pass. The installation test must remove its real system status item before returning.

- [ ] **Step 6: Run strict compile-oriented suites**

Run:

```bash
swift test --filter MenuActionLayoutTests
swift test --filter AppLocalizationTests
```

Expected: both suites pass, proving the controller still consumes the existing icon and localization contracts.

- [ ] **Step 7: Commit the AppKit presentation adapter**

```bash
git add \
  Sources/CodexRadar/App/MenuBarController.swift \
  Tests/CodexRadarTests/MenuBarControllerTests.swift
git commit -m "feat: add menu bar popover controller"
```

---

### Task 5: Replace `MenuBarExtra` with the AppKit composition

**Files:**
- Modify: `Sources/CodexRadar/App/CodexRadarApp.swift:1-78`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift:455-498`

**Interfaces:**
- Consumes: `MenuBarController`, `MenuBarPanelActions`, `MenuBarPanelRootView`, `SettingsWindowOpener`, `SettingsOpenBridgeView`, shared `DashboardStore`, and shared `SettingsSelection`.
- Produces: `AppDelegate.configure(store:settingsSelection:)`, idempotent `installMenuBarIfReady()`, lifecycle cleanup, one hidden SwiftUI keepalive scene, and no `MenuBarExtra` scene.

- [ ] **Step 1: Replace the app delegate with the configured composition root**

Update `Sources/CodexRadar/App/CodexRadarApp.swift` imports and `AppDelegate`:

```swift
import AppKit
import OSLog
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private struct Configuration {
    let store: DashboardStore
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
    settingsSelection: SettingsSelection
  ) {
    configuration = Configuration(
      store: store,
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
    guard UpdateReminderNotification.isDefaultAction(
      identifier: response.notification.request.identifier,
      actionIdentifier: response.actionIdentifier
    ) else {
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
```

- [ ] **Step 2: Configure shared state before launch**

Replace the stored-object declarations and add an initializer to `CodexRadarApp`:

```swift
@main
struct CodexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store: DashboardStore
  @StateObject private var settingsSelection: SettingsSelection
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  init() {
    let store = DashboardStore()
    let settingsSelection = SettingsSelection()
    _store = StateObject(wrappedValue: store)
    _settingsSelection = StateObject(wrappedValue: settingsSelection)
    appDelegate.configure(
      store: store,
      settingsSelection: settingsSelection
    )
  }
```

Keep the existing `selectedLocale` and `preferredColorScheme` computed properties.

- [ ] **Step 3: Replace the menu scene with the hidden lifecycle bridge**

Replace the `body` scene declaration with:

```swift
  var body: some Scene {
    Window("CodexRadarLifecycleKeepalive", id: "lifecycle-keepalive") {
      SettingsOpenBridgeView()
    }
    .defaultSize(width: 20, height: 20)
    .windowStyle(.hiddenTitleBar)

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
```

This removes `MenuBarExtra` completely while keeping SwiftUI's Settings scene alive.

- [ ] **Step 4: Remove the obsolete SwiftUI status label**

Delete `MenuBarLabel` from `MenuBarView.swift`. Keep `MenuBarIconConfiguration` because `MenuBarStatusIconRenderer` uses its asset and 18pt geometry.

- [ ] **Step 5: Format and run the full Swift test suite**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/App/CodexRadarApp.swift \
  Sources/CodexRadar/Views/MenuBarView.swift
swift test
```

Expected: SwiftPM builds successfully and 106 tests pass in 23 suites.

- [ ] **Step 6: Build and launch the packaged app**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: packaging, ad-hoc signing, verification, and launch succeed; the `CodexRadar` process stays running and exactly one status item is visible.

- [ ] **Step 7: Commit the application integration**

```bash
git add \
  Sources/CodexRadar/App/CodexRadarApp.swift \
  Sources/CodexRadar/Views/MenuBarView.swift
git commit -m "feat: use appkit menu bar entry"
```

---

### Task 6: Record the architectural decision and verify behavior

**Files:**
- Create: `docs/adr/0003-use-appkit-status-item-for-secondary-click.md`
- Verify: `docs/superpowers/specs/2026-07-26-menu-bar-secondary-click-design.md`
- Verify: all files changed in Tasks 1-5

**Interfaces:**
- Consumes: The completed implementation and approved design spec.
- Produces: ADR 0003, formatting verification, full automated verification, and a completed manual acceptance checklist.

- [ ] **Step 1: Write the ADR**

Create `docs/adr/0003-use-appkit-status-item-for-secondary-click.md`:

```markdown
# Use an AppKit status item for secondary clicks

CodexRadar uses `NSStatusItem` with a transient `NSPopover` because SwiftUI `MenuBarExtra` does not expose secondary-click handling, while the existing Menu Bar Panel is data-rich SwiftUI content rather than a command menu. The AppKit boundary owns only status-item events and popover presentation; business and view state remain in SwiftUI, and `NSMenu` should be reconsidered only if the panel is intentionally reduced to standard command items.
```

- [ ] **Step 2: Run formatting and whitespace checks**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format lint --recursive Sources Tests
git diff --check
```

Expected: both commands exit zero.

- [ ] **Step 3: Run all automated tests**

Run:

```bash
swift test
```

Expected: 106 tests pass in 23 suites with zero failures.

- [ ] **Step 4: Rebuild the packaged app**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: the packaged app verifies, launches, stays alive, and exposes exactly one Codex Radar status item.

- [ ] **Step 5: Complete manual click and dismissal acceptance**

With the packaged app running:

1. Left-click the closed status item; verify the panel opens.
2. Left-click the open status item; verify the panel closes.
3. Right-click the closed status item; verify the same panel opens.
4. Right-click the open status item; verify the panel closes.
5. Control-left-click the closed and open status item; verify the same toggle behavior.
6. Open the panel and click outside it; verify it closes and the status item highlight clears.
7. Repeat on each connected display and from a full-screen Space.

Expected: all click paths share one toggle behavior, the panel remains anchored below the icon, and no duplicate icon appears.

- [ ] **Step 6: Complete manual action and presentation acceptance**

With the panel open:

1. Trigger Refresh and Command-R; verify the panel stays open and both progress indicators update.
2. Open the Source URL; verify the popover closes before the browser activates.
3. Open Dashboard, Settings, and About; verify the popover closes first and the requested Settings Window pane appears.
4. Trigger Command-D, Command-comma, and Command-Q; verify the matching injected action runs.
5. Switch English, Simplified Chinese, Light, Dark, and System appearance; verify panel content and the status accessibility label update.
6. Exercise a forecast with and without `hasResetAlert`; verify the normal icon and red-dot icon update without creating another status item.
7. Use VoiceOver to focus and activate the status item and panel controls.

Expected: all existing behavior is preserved, outward actions dismiss explicitly, Refresh remains in place, and the AppKit controller does not own duplicated business state.

- [ ] **Step 7: Commit the ADR**

```bash
git add docs/adr/0003-use-appkit-status-item-for-secondary-click.md
git commit -m "docs: record menu bar status item decision"
```

- [ ] **Step 8: Inspect final history and worktree**

Run:

```bash
git status --short
git log --oneline -6
```

Expected: the worktree is clean and the task commits appear in dependency order.
