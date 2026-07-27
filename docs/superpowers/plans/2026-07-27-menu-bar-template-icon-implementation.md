# Menu Bar Template Radar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 menu bar 的彩色方形图标替换为已确认的 Radar Outline 单色线稿，同时保留独立的红色 reset 提示点，并确保应用程序图标完全不变。

**Architecture:** `MenuBarIconConfiguration` 使用 AppKit 矢量路径生成一个固定的 `18×18pt` template `NSImage`，由 `NSStatusBarButton` 负责随系统外观着色。`MenuBarController` 不再合成彩色位图，而是在 status button 上安装一个忽略 hit testing 的红色 badge view，并根据 forecast 状态切换其可见性。

**Tech Stack:** Swift 6、AppKit、SwiftUI、Swift Testing、SwiftPM、macOS 14+

## Global Constraints

- 只修改 menu bar 状态图标；不得修改应用程序图标及其任何展示位置。
- `Sources/CodexRadar/Resources/AppIcon.png` 与 `Sources/CodexRadar/Resources/AppIcon.icns` 必须保持 byte-for-byte 不变。
- menu bar 图标逻辑尺寸保持 `18×18pt`。
- 雷达图形必须包含外环、内环、中心点和指向右上方的扫描线。
- 雷达图形必须是 template image，由 AppKit 自动适配浅色、深色、着色菜单栏和 status button 高亮状态。
- reset 提示点继续使用 `systemRed`，但必须与 template image 分层渲染。
- badge view 必须忽略 hit testing，不得改变左键、右键、Control-left-click、popover 或高亮行为。
- 不增加第三方依赖，不改变 forecast、通知、轮询、设置或菜单面板业务逻辑。

---

## File Structure

- `Sources/CodexRadar/Views/MenuBarView.swift`
  - 保留现有 `MenuBarIconConfiguration` 位置；
  - 将 bundle PNG 加载逻辑替换为 Radar Outline 矢量绘制；
  - 不调整同文件中的菜单面板视图。
- `Sources/CodexRadar/App/MenuBarController.swift`
  - 删除位图合成 renderer；
  - 定义被动的红色 badge view；
  - 在现有 status item 生命周期内安装、更新和释放 badge。
- `Tests/CodexRadarTests/MenuActionLayoutTests.swift`
  - 验证 template image 的尺寸、template 语义和共享实例约定。
- `Tests/CodexRadarTests/MenuBarControllerTests.swift`
  - 验证 badge 的唯一性、点击穿透、初始状态和 forecast 状态切换；
  - 保留现有 status item、popover、点击与无障碍回归覆盖。
- `Sources/CodexRadar/Resources/MenuBarIcon.png`
  - 删除已不再使用的彩色 menu bar 专用资源。

---

### Task 1: Replace the color asset with a vector template radar

**Files:**
- Modify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift:29-58`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift:507-525`
- Delete: `Sources/CodexRadar/Resources/MenuBarIcon.png`

**Interfaces:**
- Consumes: AppKit `NSImage`, `NSBezierPath`, `NSColor`, and the existing `MenuBarIconConfiguration.image` call site.
- Produces: `MenuBarIconConfiguration.sideLength: CGFloat` and `MenuBarIconConfiguration.image: NSImage`, where the image is a shared `18×18pt` template image.

- [ ] **Step 1: Replace the color-asset contract with a failing template-image test**

Replace `usesAFullBleedColorMenuBarIcon()` and keep the existing size and identity tests:

```swift
@Test
@MainActor
func providesTemplateRadarMenuBarIcon() throws {
  let image = MenuBarIconConfiguration.image
  let data = try #require(image.tiffRepresentation)

  #expect(MenuBarIconConfiguration.sideLength == 18)
  #expect(
    image.size
      == NSSize(
        width: MenuBarIconConfiguration.sideLength,
        height: MenuBarIconConfiguration.sideLength
      )
  )
  #expect(image.isTemplate)
  #expect(data.isEmpty == false)
}

@Test
@MainActor
func reusesTheMenuBarIconImageInstance() {
  #expect(MenuBarIconConfiguration.image === MenuBarIconConfiguration.image)
}
```

Remove the redundant `providesMenuBarIconAtConfiguredLogicalSize()` test because the new template test owns the same size assertion.

- [ ] **Step 2: Run the focused test and verify the old color asset fails the new contract**

Run:

```bash
swift test --no-parallel --filter MenuActionLayoutTests
```

Expected: `providesTemplateRadarMenuBarIcon()` fails because the current PNG-backed image has `isTemplate == false`.

- [ ] **Step 3: Generate the confirmed Radar Outline as a template image**

Replace `MenuBarIconConfiguration` with:

```swift
enum MenuBarIconConfiguration {
  static let sideLength: CGFloat = 18

  private static let strokeWidth: CGFloat = 1.5
  private static let center = NSPoint(x: 9, y: 9)

  @MainActor
  static let image: NSImage = {
    let size = NSSize(width: sideLength, height: sideLength)
    let image = NSImage(size: size, flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()

      let ringFrames = [
        NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5),
        NSRect(x: 5, y: 5, width: 8, height: 8),
      ]
      for frame in ringFrames {
        let ring = NSBezierPath(ovalIn: frame)
        ring.lineWidth = strokeWidth
        ring.stroke()
      }

      let sweep = NSBezierPath()
      sweep.lineWidth = strokeWidth
      sweep.lineCapStyle = .round
      sweep.move(to: center)
      sweep.line(to: NSPoint(x: 13.8, y: 14.1))
      sweep.stroke()

      NSBezierPath(
        ovalIn: NSRect(x: 8, y: 8, width: 2, height: 2)
      ).fill()
      return true
    }
    image.isTemplate = true
    return image
  }()
}
```

The outer ring remains inside the 18pt canvas after accounting for the 1.5pt stroke. The center dot is drawn after the sweep line so the intersection remains visually clean.

- [ ] **Step 4: Delete the obsolete menu bar PNG**

Delete only:

```text
Sources/CodexRadar/Resources/MenuBarIcon.png
```

Do not modify or delete:

```text
Sources/CodexRadar/Resources/AppIcon.png
Sources/CodexRadar/Resources/AppIcon.icns
```

- [ ] **Step 5: Format and run the focused tests**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/Views/MenuBarView.swift \
  Tests/CodexRadarTests/MenuActionLayoutTests.swift
swift test --no-parallel --filter MenuActionLayoutTests
```

Expected: formatting exits zero and every `MenuActionLayoutTests` test passes.

- [ ] **Step 6: Commit the vector template icon**

Run:

```bash
git add \
  Sources/CodexRadar/Views/MenuBarView.swift \
  Sources/CodexRadar/Resources/MenuBarIcon.png \
  Tests/CodexRadarTests/MenuActionLayoutTests.swift
git commit -m "feat: use template radar menu bar icon"
```

Expected: one commit containing only the menu bar configuration, its focused tests, and removal of the obsolete menu bar PNG.

---

### Task 2: Preserve the red reset alert as a passive badge

**Files:**
- Modify: `Tests/CodexRadarTests/MenuBarControllerTests.swift:31-45,181-216`
- Modify: `Sources/CodexRadar/App/MenuBarController.swift:15-45,101-145,172-190,219-236`

**Interfaces:**
- Consumes: `MenuBarIconConfiguration.image`, `ResetForecastPresentation.hasResetAlert`, and the existing `MenuBarController.install()`, `refreshStatusItem()`, and `uninstall()` lifecycle.
- Produces: `MenuBarResetAlertBadgeView`, `MenuBarResetAlertBadgeView.diameter: CGFloat`, and `MenuBarController.resetAlertBadgeView: MenuBarResetAlertBadgeView?`.

- [ ] **Step 1: Replace bitmap-composition coverage with failing badge tests**

Replace `rendersStableNormalAndAlertStatusImages()` with:

```swift
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
```

Update `updatesStatusPresentationWhenForecastChanges()` so it proves the badge changes without replacing the template image:

```swift
@Test
func updatesStatusPresentationWhenForecastChanges() async throws {
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
```

- [ ] **Step 2: Run the controller tests and verify the missing badge API fails compilation**

Run:

```bash
swift test --no-parallel --filter MenuBarControllerTests
```

Expected: compilation fails because `MenuBarResetAlertBadgeView` and `resetAlertBadgeView` do not exist.

- [ ] **Step 3: Replace the bitmap renderer with a passive badge view**

Delete `MenuBarStatusIconRenderer` and add this type after `MenuBarPanelCommand`:

```swift
@MainActor
final class MenuBarResetAlertBadgeView: NSView {
  static let diameter: CGFloat = 6

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.systemRed.cgColor
    layer?.cornerRadius = Self.diameter / 2
    isHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
```

This view owns only the fixed red visual. Returning `nil` from `hitTest` preserves the status button's existing event path.

- [ ] **Step 4: Install and retain one badge with the status button**

Add the controller property:

```swift
private(set) var resetAlertBadgeView: MenuBarResetAlertBadgeView?
```

In `install()`, configure the template image and badge before assigning `statusItem`:

```swift
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
```

The existing `guard statusItem == nil` keeps both the status item and badge idempotent.

- [ ] **Step 5: Update badge visibility without replacing the template image**

Replace the alert-image branch in `refreshStatusItem()` with:

```swift
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
```

In `uninstall()`, release the overlay before removing the status item:

```swift
resetAlertBadgeView?.removeFromSuperview()
resetAlertBadgeView = nil
```

Keep `lastHasResetAlert = nil` at the end so reinstalling recomputes the current visibility.

- [ ] **Step 6: Format and run the AppKit controller tests**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format format --in-place \
  Sources/CodexRadar/App/MenuBarController.swift \
  Tests/CodexRadarTests/MenuBarControllerTests.swift
swift test --no-parallel --filter MenuBarControllerTests
swift test --no-parallel --filter MenuActionLayoutTests
```

Expected: both focused suites pass. The existing click, popover highlight, installation idempotence, forecast update, localization, and accessibility tests remain green.

- [ ] **Step 7: Commit the reset-alert overlay**

Run:

```bash
git add \
  Sources/CodexRadar/App/MenuBarController.swift \
  Tests/CodexRadarTests/MenuBarControllerTests.swift
git commit -m "feat: preserve menu bar reset badge"
```

Expected: one focused commit containing the badge implementation and controller tests.

---

### Task 3: Verify packaging, regressions, and visual behavior

**Files:**
- Verify only: `Sources/CodexRadar/Resources/AppIcon.png`
- Verify only: `Sources/CodexRadar/Resources/AppIcon.icns`
- Verify only: `Sources/CodexRadar/Views/ApplicationIcon.swift`
- Verify only: packaged `dist/CodexRadar.app`

**Interfaces:**
- Consumes: the template image and badge delivered by Tasks 1 and 2.
- Produces: a formatted, tested, packaged application with unchanged application-icon assets and an inspected menu bar rendering.

- [ ] **Step 1: Lint all Swift sources and inspect the final diff**

Run:

```bash
/Library/Developer/CommandLineTools/usr/bin/swift-format lint --recursive Sources Tests
git diff --check HEAD~2..HEAD
git status --short
```

Expected: lint and whitespace checks exit zero. Status contains no uncommitted source changes.

- [ ] **Step 2: Run the complete test suite using the repository's AppKit isolation**

Run:

```bash
appkit_test_suites='MenuActionLayoutTests|MenuBarControllerTests|MenuBarPanelActionsTests|SettingsWindowBridgeTests'
swift test --no-parallel --filter "$appkit_test_suites"
swift test --no-parallel --skip "$appkit_test_suites"
```

Expected: both commands exit zero with no failures.

- [ ] **Step 3: Build, sign, verify, and launch the local app**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: packaging, ad-hoc signing, bundle verification, launch, and process-liveness checks all exit zero.

- [ ] **Step 4: Verify resource scope**

Run:

```bash
find dist/CodexRadar.app -name 'MenuBarIcon.png' -print
find dist/CodexRadar.app -name 'AppIcon.icns' -print
git diff HEAD~2 --exit-code -- \
  Sources/CodexRadar/Resources/AppIcon.png \
  Sources/CodexRadar/Resources/AppIcon.icns \
  Sources/CodexRadar/Views/ApplicationIcon.swift
```

Expected:

- the first `find` prints nothing;
- the second `find` prints the packaged `AppIcon.icns` path;
- `git diff --exit-code` exits zero, proving the implementation commits did not alter application-icon files.

- [ ] **Step 5: Inspect the menu bar in both system appearances**

With the packaged app running, verify:

1. The menu bar shows the approved Radar Outline without a blue square background.
2. The outer ring, inner ring, center point, and upper-right sweep remain legible at 18pt.
3. The glyph follows the system foreground color in light and dark appearances.
4. The glyph follows status-button highlight rendering while the popover is open.
5. The red reset badge appears only for `hasResetAlert == true`.
6. Left-click, right-click, and Control-left-click still toggle the same popover.
7. Finder, Dock, About, and the app bundle continue to show the original application icon.

If only visual coordinates require adjustment, change only the numeric ring, sweep, or badge-offset constants, rerun Tasks 1–3 verification commands, and amend neither historical design decisions nor application-icon resources.
