# Sparkle Gentle Update Reminders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为后台运行的 CodexRadar 增加真实的 Sparkle gentle update reminder，消除警告，同时保留与 CodexBar 对齐的标准 Sparkle 检查、窗口、下载和安装路径。

**Architecture:** `SparkleUpdaterController` 继续拥有 `SPUStandardUpdaterController`，新增 `SPUStandardUserDriverDelegate` 只负责把后台发现更新的生命周期转发给轻量的 `UpdateReminderNotificationService`。`AppDelegate` 只路由稳定通知 identifier 的默认点击动作，通过 `UpdaterSettingsModel` 的内部入口重新聚焦 Sparkle 标准窗口；通知权限或投递失败不改变 updater 会话。

**Tech Stack:** Swift 6、SwiftUI、AppKit、UserNotifications、OSLog、Sparkle 2.9.4、Swift Testing、Swift Package Manager。

## Global Constraints

- 支持 macOS 14 及以上版本。
- Sparkle 依赖保持精确锁定在 `2.9.4`。
- 不增加新的 Swift package 依赖。
- 不修改 release workflow、appcast、Ed25519 签名或安装机制。
- 不自定义更新窗口、下载器、安装器或权限提升逻辑。
- Sparkle 标准更新窗口始终保留为兜底，系统通知只能是辅助提醒。
- 应用继续使用 `.accessory` activation policy，不创建 Dock 图标或 Dock badge。
- 后台检查可以发送提醒，用户主动检查不得发送重复提醒。
- 通知功能复用现有授权状态，不新增通知权限弹窗。
- 与 CodexBar 的差异仅限本功能要求的 `SPUStandardUserDriverDelegate` 和 Notification Center 桥接。
- 所有代码、注释、标识符和提交信息使用 English。
- 生产代码必须由先失败的回归测试驱动。

---

## File Map

- `Sources/CodexRadar/Updates/UpdateReminderNotificationService.swift`：更新提醒文案、稳定 identifier、点击匹配、授权检查、投递和幂等清理。
- `Tests/CodexRadarTests/UpdateReminderNotificationServiceTests.swift`：通知文案、授权降级、去重清理、投递失败和点击匹配测试。
- `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`：英文更新提醒文案。
- `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`：简体中文更新提醒文案。
- `Tests/CodexRadarTests/AppLocalizationTests.swift`：提醒文案本地化测试。
- `Sources/CodexRadar/Updates/UpdaterProviding.swift`：通知点击专用的 updater 展示入口。
- `Tests/CodexRadarTests/UpdaterSettingsModelTests.swift`：通知点击绕过 UI availability guard 的测试。
- `Sources/CodexRadar/App/CodexRadarApp.swift`：`UNUserNotificationCenterDelegate` 点击路由。
- `Sources/CodexRadar/Updates/SparkleUpdaterController.swift`：gentle-reminder policy、delegate 声明和 Sparkle 生命周期转发。
- `Tests/CodexRadarTests/UpdateReminderPolicyTests.swift`：用户主动与后台检查的提醒决策测试。
- `docs/superpowers/specs/2026-07-22-sparkle-gentle-update-reminders-design.md`：已批准设计依据。

### Task 1: Add the Update Reminder Notification Service

**Files:**
- Create: `Sources/CodexRadar/Updates/UpdateReminderNotificationService.swift`
- Create: `Tests/CodexRadarTests/UpdateReminderNotificationServiceTests.swift`
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/CodexRadarTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: `AppLocalization.string(_:language:bundle:)`, `AppLanguage.selected`, and `UNUserNotificationCenter`.
- Produces: `UpdateReminderNotification.identifier: String`, `UpdateReminderNotification.isDefaultAction(identifier:actionIdentifier:) -> Bool`, `UpdateReminderNotificationPresentation.localized(displayVersion:language:bundle:)`, `UpdateReminderNotificationService.post(displayVersion:language:bundle:) async`, and `UpdateReminderNotificationService.clear()`.

- [ ] **Step 1: Write the failing notification service tests**

Create `Tests/CodexRadarTests/UpdateReminderNotificationServiceTests.swift`:

```swift
import Foundation
import Testing
@preconcurrency import UserNotifications

@testable import CodexRadar

@MainActor
struct UpdateReminderNotificationServiceTests {
  @Test
  func buildsLocalizedPresentation() {
    #expect(
      UpdateReminderNotificationPresentation.localized(
        displayVersion: "1.2.3",
        language: .english,
        bundle: .module
      ) == UpdateReminderNotificationPresentation(
        title: "A new CodexRadar update is available",
        body: "Version 1.2.3 is now available."
      )
    )
    #expect(
      UpdateReminderNotificationPresentation.localized(
        displayVersion: "1.2.3",
        language: .simplifiedChinese,
        bundle: .module
      ) == UpdateReminderNotificationPresentation(
        title: "CodexRadar \u{6709}\u{65B0}\u{7248}\u{672C}\u{53EF}\u{7528}",
        body: "\u{7248}\u{672C} 1.2.3 \u{73B0}\u{5DF2}\u{53EF}\u{7528}\u{3002}"
      )
    )
  }

  @Test
  func postsOneStableReminderWhenAuthorized() async throws {
    var addedRequests: [UNNotificationRequest] = []
    var pendingRemovals: [[String]] = []
    var deliveredRemovals: [[String]] = []
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .authorized },
      addRequest: { addedRequests.append($0) },
      removePending: { pendingRemovals.append($0) },
      removeDelivered: { deliveredRemovals.append($0) }
    )

    await service.post(
      displayVersion: "1.2.3",
      language: .english,
      bundle: .module
    )

    let request = try #require(addedRequests.first)
    #expect(addedRequests.count == 1)
    #expect(request.identifier == UpdateReminderNotification.identifier)
    #expect(request.content.title == "A new CodexRadar update is available")
    #expect(request.content.body == "Version 1.2.3 is now available.")
    #expect(request.content.threadIdentifier == "codex-radar-update")
    #expect(pendingRemovals == [[UpdateReminderNotification.identifier]])
    #expect(deliveredRemovals == [[UpdateReminderNotification.identifier]])
  }

  @Test
  func skipsReminderWithoutAuthorization() async {
    var addCount = 0
    var clearCount = 0
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .denied },
      addRequest: { _ in addCount += 1 },
      removePending: { _ in clearCount += 1 },
      removeDelivered: { _ in clearCount += 1 }
    )

    await service.post(displayVersion: "1.2.3")

    #expect(addCount == 0)
    #expect(clearCount == 0)
  }

  @Test
  func swallowsDeliveryFailureAfterRemovingStaleReminder() async {
    var addCount = 0
    var clearCount = 0
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .provisional },
      addRequest: { _ in
        addCount += 1
        throw NotificationFailure.delivery
      },
      removePending: { _ in clearCount += 1 },
      removeDelivered: { _ in clearCount += 1 }
    )

    await service.post(displayVersion: "1.2.3")

    #expect(addCount == 1)
    #expect(clearCount == 2)
  }

  @Test
  func clearsPendingAndDeliveredReminderIdempotently() {
    var pendingRemovals: [[String]] = []
    var deliveredRemovals: [[String]] = []
    let service = UpdateReminderNotificationService(
      authorizationStatus: { .authorized },
      addRequest: { _ in },
      removePending: { pendingRemovals.append($0) },
      removeDelivered: { deliveredRemovals.append($0) }
    )

    service.clear()
    service.clear()

    let expected = [
      [UpdateReminderNotification.identifier],
      [UpdateReminderNotification.identifier],
    ]
    #expect(pendingRemovals == expected)
    #expect(deliveredRemovals == expected)
  }
}

private enum NotificationFailure: Error {
  case delivery
}
```

- [ ] **Step 2: Extend the localization tests with the failing reminder expectations**

Add to `localizesUpdateControlsInEnglish()` in `Tests/CodexRadarTests/AppLocalizationTests.swift`:

```swift
#expect(
  localized("A new CodexRadar update is available", language: .english)
    == "A new CodexRadar update is available"
)
#expect(
  localized("Version %@ is now available.", language: .english)
    == "Version %@ is now available."
)
```

Add to `localizesUpdateControlsInSimplifiedChinese()`:

```swift
#expect(
  localized("A new CodexRadar update is available", language: .simplifiedChinese)
    == "CodexRadar \u{6709}\u{65B0}\u{7248}\u{672C}\u{53EF}\u{7528}"
)
#expect(
  localized("Version %@ is now available.", language: .simplifiedChinese)
    == "\u{7248}\u{672C} %@ \u{73B0}\u{5DF2}\u{53EF}\u{7528}\u{3002}"
)
```

- [ ] **Step 3: Verify the new tests are RED**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdateReminderNotificationServiceTests
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter AppLocalizationTests
```

Expected: the first command fails because the reminder types do not exist; the second fails because the Simplified Chinese keys are missing.

- [ ] **Step 4: Implement the notification presentation, routing, delivery, and cleanup**

Create `Sources/CodexRadar/Updates/UpdateReminderNotificationService.swift`:

```swift
import Foundation
import OSLog
@preconcurrency import UserNotifications

struct UpdateReminderNotificationPresentation: Equatable {
  let title: String
  let body: String

  static func localized(
    displayVersion: String,
    language: AppLanguage = .selected,
    bundle: Bundle = .main
  ) -> UpdateReminderNotificationPresentation {
    UpdateReminderNotificationPresentation(
      title: AppLocalization.string(
        "A new CodexRadar update is available",
        language: language,
        bundle: bundle
      ),
      body: String(
        format: AppLocalization.string(
          "Version %@ is now available.",
          language: language,
          bundle: bundle
        ),
        displayVersion
      )
    )
  }
}

enum UpdateReminderNotification {
  static let identifier = "codex-radar-update-available"

  static func isDefaultAction(
    identifier: String,
    actionIdentifier: String
  ) -> Bool {
    identifier == self.identifier
      && actionIdentifier == UNNotificationDefaultActionIdentifier
  }
}

@MainActor
final class UpdateReminderNotificationService {
  typealias AuthorizationStatusProvider = @MainActor () async -> UNAuthorizationStatus
  typealias AddRequest = @MainActor (UNNotificationRequest) async throws -> Void
  typealias RemoveRequests = @MainActor ([String]) -> Void

  private static let logger = Logger(
    subsystem: "com.terence.codex-radar",
    category: "updates"
  )

  private let authorizationStatus: AuthorizationStatusProvider
  private let addRequest: AddRequest
  private let removePending: RemoveRequests
  private let removeDelivered: RemoveRequests

  init(center: UNUserNotificationCenter = .current()) {
    authorizationStatus = {
      let settings = await center.notificationSettings()
      return settings.authorizationStatus
    }
    addRequest = { request in
      try await center.add(request)
    }
    removePending = { identifiers in
      center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    removeDelivered = { identifiers in
      center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
  }

  init(
    authorizationStatus: @escaping AuthorizationStatusProvider,
    addRequest: @escaping AddRequest,
    removePending: @escaping RemoveRequests,
    removeDelivered: @escaping RemoveRequests
  ) {
    self.authorizationStatus = authorizationStatus
    self.addRequest = addRequest
    self.removePending = removePending
    self.removeDelivered = removeDelivered
  }

  func post(
    displayVersion: String,
    language: AppLanguage = .selected,
    bundle: Bundle = .main
  ) async {
    let status = await authorizationStatus()
    guard status == .authorized || status == .provisional else { return }

    let presentation = UpdateReminderNotificationPresentation.localized(
      displayVersion: displayVersion,
      language: language,
      bundle: bundle
    )
    let content = UNMutableNotificationContent()
    content.title = presentation.title
    content.body = presentation.body
    content.sound = .default
    content.threadIdentifier = "codex-radar-update"

    clear()
    let request = UNNotificationRequest(
      identifier: UpdateReminderNotification.identifier,
      content: content,
      trigger: nil
    )
    do {
      try await addRequest(request)
    } catch {
      let error = error as NSError
      Self.logger.error(
        "Failed to post update reminder: domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
      )
    }
  }

  func clear() {
    let identifiers = [UpdateReminderNotification.identifier]
    removePending(identifiers)
    removeDelivered(identifiers)
  }
}
```

- [ ] **Step 5: Add the localized resources**

Add to `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`:

```text
"A new CodexRadar update is available" = "A new CodexRadar update is available";
"Version %@ is now available." = "Version %@ is now available.";
```

Add to `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`:

```text
"A new CodexRadar update is available" = "CodexRadar \U6709\U65B0\U7248\U672C\U53EF\U7528";
"Version %@ is now available." = "\U7248\U672C %@ \U73B0\U5DF2\U53EF\U7528\U3002";
```

- [ ] **Step 6: Verify the notification and localization tests are GREEN**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdateReminderNotificationServiceTests
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter AppLocalizationTests
```

Expected: both suites PASS.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/CodexRadar/Updates/UpdateReminderNotificationService.swift Sources/CodexRadar/Resources/en.lproj/Localizable.strings Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings Tests/CodexRadarTests/UpdateReminderNotificationServiceTests.swift Tests/CodexRadarTests/AppLocalizationTests.swift
git commit -m "feat: add update reminder notifications"
```

### Task 2: Route Notification Clicks to the Standard Updater

**Files:**
- Modify: `Tests/CodexRadarTests/UpdaterSettingsModelTests.swift`
- Modify: `Tests/CodexRadarTests/UpdateReminderNotificationServiceTests.swift`
- Modify: `Sources/CodexRadar/Updates/UpdaterProviding.swift`
- Modify: `Sources/CodexRadar/App/CodexRadarApp.swift`

**Interfaces:**
- Consumes: `UpdateReminderNotification.isDefaultAction(identifier:actionIdentifier:)` and `UpdaterProviding.checkForUpdates()`.
- Produces: `UpdaterSettingsModel.showUpdateFromReminder()` and the `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:) async` route.

- [ ] **Step 1: Write the failing updater reminder route tests**

Add to `UpdaterSettingsModelTests`:

```swift
@Test("notification reminder reopens an existing updater session")
func reopensUpdaterSessionFromReminder() {
  let provider = FakeUpdaterProvider(
    isAvailable: true,
    canCheckForUpdates: false
  )
  let model = UpdaterSettingsModel(provider: provider)

  model.showUpdateFromReminder()

  #expect(provider.checkForUpdatesCallCount == 1)
}

@Test("notification reminder does not invoke a disabled provider")
func ignoresReminderForDisabledProvider() {
  let provider = FakeUpdaterProvider(
    isAvailable: false,
    canCheckForUpdates: false
  )
  let model = UpdaterSettingsModel(provider: provider)

  model.showUpdateFromReminder()

  #expect(provider.checkForUpdatesCallCount == 0)
}
```

Add to `UpdateReminderNotificationServiceTests`:

```swift
@Test
func matchesOnlyTheUpdateReminderDefaultAction() {
  #expect(
    UpdateReminderNotification.isDefaultAction(
      identifier: UpdateReminderNotification.identifier,
      actionIdentifier: UNNotificationDefaultActionIdentifier
    )
  )
  #expect(
    UpdateReminderNotification.isDefaultAction(
      identifier: "reset-signal",
      actionIdentifier: UNNotificationDefaultActionIdentifier
    ) == false
  )
  #expect(
    UpdateReminderNotification.isDefaultAction(
      identifier: UpdateReminderNotification.identifier,
      actionIdentifier: UNNotificationDismissActionIdentifier
    ) == false
  )
}
```

- [ ] **Step 2: Verify the updater route test is RED**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdaterSettingsModelTests
```

Expected: FAIL at compile time because `UpdaterSettingsModel.showUpdateFromReminder()` does not exist.

- [ ] **Step 3: Add the notification-specific updater entry point**

Add to `UpdaterSettingsModel` in `Sources/CodexRadar/Updates/UpdaterProviding.swift` immediately after `checkForUpdates()`:

```swift
func showUpdateFromReminder() {
  guard provider.isAvailable else { return }
  provider.checkForUpdates()
  refresh()
}
```

This intentionally does not check `provider.canCheckForUpdates`. The reminder is created after Sparkle has already found an update, so the existing session may temporarily make the About button unavailable even though `checkForUpdates` is the documented way to bring the existing Sparkle window back into focus.

- [ ] **Step 4: Route only the update reminder default action**

Add to `AppDelegate` in `Sources/CodexRadar/App/CodexRadarApp.swift` after `willPresent`:

```swift
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
```

- [ ] **Step 5: Verify focused routing tests and compile the app**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdaterSettingsModelTests
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdateReminderNotificationServiceTests
swift build
```

Expected: both suites PASS and the executable target builds without actor-isolation or delegate-conformance errors.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/CodexRadar/Updates/UpdaterProviding.swift Sources/CodexRadar/App/CodexRadarApp.swift Tests/CodexRadarTests/UpdaterSettingsModelTests.swift Tests/CodexRadarTests/UpdateReminderNotificationServiceTests.swift
git commit -m "feat: route update reminder actions"
```

### Task 3: Wire Sparkle Gentle Reminder Lifecycle

**Files:**
- Create: `Tests/CodexRadarTests/UpdateReminderPolicyTests.swift`
- Modify: `Sources/CodexRadar/Updates/SparkleUpdaterController.swift`

**Interfaces:**
- Consumes: `UpdateReminderNotificationService.post(displayVersion:language:bundle:) async` and `UpdateReminderNotificationService.clear()`.
- Produces: `UpdateReminderPolicy.shouldPost(userInitiated:) -> Bool` and a `SparkleUpdaterController` conforming to `SPUStandardUserDriverDelegate`.

- [ ] **Step 1: Write the failing reminder policy tests**

Create `Tests/CodexRadarTests/UpdateReminderPolicyTests.swift`:

```swift
import Testing

@testable import CodexRadar

struct UpdateReminderPolicyTests {
  @Test
  func postsOnlyForScheduledUpdates() {
    #expect(UpdateReminderPolicy.shouldPost(userInitiated: false))
    #expect(UpdateReminderPolicy.shouldPost(userInitiated: true) == false)
  }
}
```

- [ ] **Step 2: Verify the policy test is RED**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdateReminderPolicyTests
```

Expected: FAIL at compile time because `UpdateReminderPolicy` does not exist.

- [ ] **Step 3: Add the policy and retain the reminder service**

Add above `SparkleUpdaterController` in `Sources/CodexRadar/Updates/SparkleUpdaterController.swift`:

```swift
enum UpdateReminderPolicy {
  static func shouldPost(userInitiated: Bool) -> Bool {
    !userInitiated
  }
}
```

Extend the controller conformance:

```diff
@MainActor
-final class SparkleUpdaterController: NSObject, UpdaterProviding, UpdaterStateChangeNotifying,
-  SPUUpdaterDelegate
+final class SparkleUpdaterController: NSObject, UpdaterProviding, UpdaterStateChangeNotifying,
+  SPUUpdaterDelegate, SPUStandardUserDriverDelegate
 {
```

Add the notification dependency immediately after the existing installation-location dependencies:

```diff
   private let bundleURL: URL
   private let homeURL: URL
   private let isWritable: (URL) -> Bool
+  private let updateReminderNotifications: UpdateReminderNotificationService
   private var isShowingInstallationAlert = false
```

Replace the initializer signature and assign the dependency before `super.init()`:

```swift
init(
  bundleURL: URL = Bundle.main.bundleURL,
  homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
  isWritable: @escaping (URL) -> Bool = {
    guard
      let resourceValues = try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
      let isReadOnly = resourceValues.volumeIsReadOnly
    else {
      return false
    }

    return !isReadOnly
  },
  updateReminderNotifications: UpdateReminderNotificationService =
    UpdateReminderNotificationService()
) {
  self.bundleURL = bundleURL
  self.homeURL = homeURL
  self.isWritable = isWritable
  self.updateReminderNotifications = updateReminderNotifications
  super.init()
  _ = standardUpdaterController
  canCheckForUpdatesObservation = standardUpdaterController.updater.observe(
    \.canCheckForUpdates,
    options: [.new]
  ) { [weak self] _, _ in
    Task { @MainActor [weak self] in
      self?.updaterStateDidChange?()
    }
  }
}
```

- [ ] **Step 4: Pass the controller as Sparkle's user driver delegate**

Change the lazy controller construction:

```swift
private lazy var standardUpdaterController = SPUStandardUpdaterController(
  startingUpdater: true,
  updaterDelegate: self,
  userDriverDelegate: self
)
```

The controller is already retained for the app lifetime through `UpdaterSettingsModel`, so Sparkle's weak delegate reference remains valid.

- [ ] **Step 5: Implement the standard user driver delegate lifecycle**

Add before the existing `SPUUpdaterDelegate` error callback:

```swift
var supportsGentleScheduledUpdateReminders: Bool {
  true
}

func standardUserDriverShouldHandleShowingScheduledUpdate(
  _ update: SUAppcastItem,
  andInImmediateFocus immediateFocus: Bool
) -> Bool {
  true
}

func standardUserDriverWillHandleShowingUpdate(
  _ handleShowingUpdate: Bool,
  forUpdate update: SUAppcastItem,
  state: SPUUserUpdateState
) {
  guard UpdateReminderPolicy.shouldPost(userInitiated: state.userInitiated) else {
    return
  }

  let displayVersion = update.displayVersionString
  Task { @MainActor [weak self] in
    await self?.updateReminderNotifications.post(displayVersion: displayVersion)
  }
}

func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
  updateReminderNotifications.clear()
}

func standardUserDriverWillFinishUpdateSession() {
  updateReminderNotifications.clear()
}
```

The unused delegate arguments are intentionally left unnamed in behavior: returning `true` preserves Sparkle's standard UI in both immediate and background cases, while `state.userInitiated` is the only reminder decision input.

- [ ] **Step 6: Verify the policy, updater, and full regression suite**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter UpdateReminderPolicyTests
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift build
git diff --check
```

Expected: the focused policy test and full suite PASS, the executable builds, and `git diff --check` reports no whitespace errors.

- [ ] **Step 7: Perform source-level alignment checks**

Run:

```bash
rg -n "userDriverDelegate: self|supportsGentleScheduledUpdateReminders|standardUserDriverWillHandleShowingUpdate|standardUserDriverDidReceiveUserAttention|standardUserDriverWillFinishUpdateSession" Sources/CodexRadar/Updates/SparkleUpdaterController.swift
rg -n "SPUStandardUpdaterController|SPUUpdaterDelegate|checkForUpdates" Sources/CodexRadar/Updates/SparkleUpdaterController.swift Sources/CodexRadar/Updates/UpdaterProviding.swift
```

Expected: the first command finds all gentle-reminder hooks; the second confirms the existing standard Sparkle controller, updater delegate, and check path remain in use.

- [ ] **Step 8: Commit Task 3**

```bash
git add Sources/CodexRadar/Updates/SparkleUpdaterController.swift Tests/CodexRadarTests/UpdateReminderPolicyTests.swift
git commit -m "feat: handle Sparkle gentle reminders"
```

### Task 4: Qualify the Background Reminder Experience

**Files:**
- Verify only: no source changes expected.

**Interfaces:**
- Consumes: a release-like CodexRadar app, an appcast signed by the configured Ed25519 key, and a higher signed update archive.
- Produces: manual evidence for the accepted behavior matrix; it does not change product code or release assets.

- [ ] **Step 1: Confirm the installed app is the release-like build under test**

Run:

```bash
defaults read com.terence.codex-radar SULastCheckTime
plutil -p /Users/tangwz/Applications/CodexRadar.app/Contents/Info.plist | rg "SUFeedURL|SUPublicEDKey|SUEnableAutomaticChecks|SUAutomaticallyUpdate|SUVerifyUpdateBeforeExtraction|SURequireSignedFeed"
```

Expected: the Info.plist contains the approved production security settings. Record the current `SULastCheckTime` value before changing it.

- [ ] **Step 2: Exercise the near-launch scheduled check**

Run:

```bash
defaults delete com.terence.codex-radar SULastCheckTime
open /Users/tangwz/Applications/CodexRadar.app
```

Expected: Sparkle may present the standard update window in immediate focus near launch; one update notification may also be posted because this is a scheduled rather than user-initiated check.

- [ ] **Step 3: Exercise the delayed background check**

Quit the app, then run:

```bash
defaults write com.terence.codex-radar SULastCheckTime -date "$(date -v-1d -v+30S)"
open /Users/tangwz/Applications/CodexRadar.app
```

Expected: after the scheduled delay, exactly one local update notification appears and the Sparkle standard window remains available behind the active app.

- [ ] **Step 4: Verify reminder focus and cleanup**

Click the update notification, then inspect the update UI.

Expected: the existing Sparkle update window comes to the front. Giving the window attention, skipping the update, closing the session, or reaching an updater error removes the delivered notification.

- [ ] **Step 5: Verify manual-check and denied-permission fallbacks**

Use About → Check for Updates, then repeat the scheduled check with notifications disabled in System Settings.

Expected: the manual check never posts an update notification. With notifications denied, Sparkle's standard window and update flow continue to work.

- [ ] **Step 6: Verify the warning is absent**

Run while exercising a scheduled update check:

```bash
log stream --style compact --predicate 'process == "CodexRadar" AND eventMessage CONTAINS[c] "gentle"'
```

Expected: no `Background app automatically schedules for update checks but does not implement gentle reminders` warning appears.

If a higher correctly signed update and feed are unavailable, record Task 4 as blocked by qualification infrastructure. Do not claim end-to-end automatic update success from build and unit-test evidence alone.

## Final Acceptance Checklist

- [ ] `userDriverDelegate` is `self` and remains retained for the application lifetime.
- [ ] `supportsGentleScheduledUpdateReminders` returns `true` only alongside a real scheduled reminder.
- [ ] Sparkle always retains responsibility for its standard update window.
- [ ] User-driven checks do not post local update notifications.
- [ ] Scheduled checks use one stable notification identifier.
- [ ] Clicking that notification reopens the Sparkle session even when the About button is temporarily disabled.
- [ ] Attention and session-finish callbacks clear pending and delivered reminders.
- [ ] Notification authorization or delivery failure does not abort the updater.
- [ ] Reset forecast and other notifications do not trigger an update check.
- [ ] The app remains an `.accessory` menu bar application.
- [ ] Focused tests, full tests, build, localization, and whitespace checks pass.
- [ ] A signed higher-version qualification feed is used before claiming end-to-end success.
