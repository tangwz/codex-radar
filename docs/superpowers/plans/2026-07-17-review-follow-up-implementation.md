# GitHub Review Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复通知投递失败时提前消费 signal 和跨语言 forecast issue 无法清理的问题，同时保留服务端权威的 Signal ID 与 stale 语义。

**Architecture:** `ResetNotificationService` 把系统通知投递抽象为可注入 closure，并只在投递成功后持久化 baseline；`DashboardStore` 在 `304 Not Modified` 时重新观察当前 forecast，为未成功投递的 signal 提供重试入口。forecast issue 使用独立语义槽位管理已渲染消息，不再依赖当前语言字符串前缀。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing、UserNotifications、Swift Package Manager、GitHub review threads。

## Global Constraints

- 支持 macOS 14 及以上版本。
- 不增加新的 Swift package 依赖。
- 不改变 `/v1/current` 公共协议、Signal ID、TTL 或 stale 语义。
- 不阻塞初始 forecast 拉取等待通知授权。
- 不增加独立通知重试计时器。
- 所有代码、注释、标识符和提交信息使用 English。
- 生产代码必须由先失败的回归测试驱动。

---

## File Map

- `Sources/CodexRadar/Services/ResetNotificationService.swift`：通知决策、系统投递和 baseline 持久化边界。
- `Sources/CodexRadar/Stores/DashboardStore.swift`：forecast 拉取结果、通知观察和 issue 生命周期。
- `Tests/CodexRadarTests/ResetNotificationPolicyTests.swift`：通知决策、投递失败重试和成功去重。
- `Tests/CodexRadarTests/DashboardStoreForecastTests.swift`：not-modified 通知观察和跨语言 issue 生命周期。
- `docs/superpowers/specs/2026-07-17-review-follow-up-design.md`：已确认设计依据。

### Task 1: Consume Notification Signals Only After Successful Delivery

**Files:**
- Modify: `Tests/CodexRadarTests/ResetNotificationPolicyTests.swift`
- Modify: `Tests/CodexRadarTests/DashboardStoreForecastTests.swift`
- Modify: `Sources/CodexRadar/Services/ResetNotificationService.swift`
- Modify: `Sources/CodexRadar/Stores/DashboardStore.swift`

**Interfaces:**
- Consumes: `ResetNotificationPolicy.decision(forecast:hasBaseline:lastSignalID:)` and `ResetForecastFetchResult.notModified`.
- Produces: `ResetNotificationService.DeliverNotification`, injectable `ResetNotificationService.init(center:defaults:deliverNotification:)`, and retry observation on not-modified responses.

- [ ] **Step 1: Write the failing delivery retry test**

Add inside `ResetNotificationPolicyTests`:

```swift
@MainActor
@Test
func retriesUnconsumedSignalUntilDeliverySucceeds() async throws {
  let suiteName = "ResetNotificationPolicyTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var deliveryResults = [false, true]
  var deliveredSignalIDs: [String] = []
  let service = ResetNotificationService(
    defaults: defaults,
    deliverNotification: { _, signalID in
      deliveredSignalIDs.append(signalID)
      return deliveryResults.removeFirst()
    }
  )

  await service.observe(makeForecast(status: .monitoring))
  let forecast = makeForecast(status: .announced, signalID: "signal-2")

  await service.observe(forecast)
  await service.observe(forecast)
  await service.observe(forecast)

  #expect(deliveredSignalIDs == ["signal-2", "signal-2"])
}
```

- [ ] **Step 2: Verify the delivery test is RED**

Run:

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter retriesUnconsumedSignalUntilDeliverySucceeds
```

Expected: FAIL at compile time because `ResetNotificationService` does not accept `defaults` or `deliverNotification`.

- [ ] **Step 3: Write the failing not-modified observation test**

Rename `treatsNotModifiedAsSuccessWithoutChangingOrObservingForecast` to `treatsNotModifiedAsSuccessAndReobservesCurrentForecast`, then replace its final expectation:

```swift
#expect(await notifications.forecasts == [forecast, forecast])
```

- [ ] **Step 4: Verify the store test is RED**

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter treatsNotModifiedAsSuccessAndReobservesCurrentForecast
```

Expected: FAIL because only the updated response is observed.

- [ ] **Step 5: Implement injectable delivery and success-only persistence**

Replace the stored notification dependencies and add the initializer in `ResetNotificationService`:

```swift
typealias DeliverNotification = @MainActor (ResetForecast, String) async -> Bool

private let center: UNUserNotificationCenter
private let defaults: UserDefaults
private let deliverNotification: DeliverNotification
private let hasBaselineKey = "hasResetSignalBaseline"
private let lastSignalIDKey = "lastObservedResetSignalID"

init(
  center: UNUserNotificationCenter = .current(),
  defaults: UserDefaults = .standard,
  deliverNotification: DeliverNotification? = nil
) {
  self.center = center
  self.defaults = defaults
  self.deliverNotification = deliverNotification ?? { forecast, signalID in
    await Self.sendNotification(
      for: forecast,
      signalID: signalID,
      center: center
    )
  }
}
```

Change the `.notify` branch:

```swift
case .notify(let signalID):
  guard await deliverNotification(forecast, signalID) else { return }
  persistBaseline(signalID)
```

Change the sender signature and all failure exits to `false`; return `true` only after `center.add` succeeds:

```swift
private static func sendNotification(
  for forecast: ResetForecast,
  signalID: String,
  center: UNUserNotificationCenter
) async -> Bool {
  guard let presentation = ResetNotificationPresentation(forecast: forecast) else {
    return false
  }
  let settings = await center.notificationSettings()
  guard settings.authorizationStatus == .authorized
    || settings.authorizationStatus == .provisional
  else {
    return false
  }

  let content = UNMutableNotificationContent()
  let locale = AppLanguage.selected.locale
  switch presentation.body {
  case .exact(let at):
    content.title = AppLocalization.string("Codex reset announced")
    content.body = String(
      format: AppLocalization.string("A reset is expected by %@."),
      DisplayFormatting.absoluteDate(at, locale: locale)
    )
  case .estimated(let from, let to):
    content.title = AppLocalization.string("Codex reset announced")
    content.body = String(
      format: AppLocalization.string("A reset is expected between %@ and %@."),
      DisplayFormatting.absoluteDate(from, locale: locale),
      DisplayFormatting.absoluteDate(to, locale: locale)
    )
  case .imminent:
    content.title = AppLocalization.string("Codex reset announced")
    content.body = AppLocalization.string("A Codex reset is expected soon.")
  case .completed:
    content.title = AppLocalization.string("Codex reset completed")
    content.body = AppLocalization.string("Codex is available to use now.")
  }
  content.sound = .default
  content.threadIdentifier = "codex-reset"

  let request = UNNotificationRequest(
    identifier: signalID,
    content: content,
    trigger: nil
  )
  do {
    try await center.add(request)
    return true
  } catch {
    return false
  }
}
```

- [ ] **Step 6: Reobserve the current forecast after not-modified**

Update `DashboardStore.loadForecast`:

```swift
case .notModified:
  consecutiveForecastFailures = 0
  removeForecastIssue()
  await observeForecast(forecast)
```

- [ ] **Step 7: Verify focused suites are GREEN**

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter ResetNotificationPolicyTests
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter DashboardStoreForecastTests
```

Expected: both suites PASS.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/CodexRadar/Services/ResetNotificationService.swift Sources/CodexRadar/Stores/DashboardStore.swift Tests/CodexRadarTests/ResetNotificationPolicyTests.swift Tests/CodexRadarTests/DashboardStoreForecastTests.swift
git commit -m "fix: retry undelivered reset notifications"
```

### Task 2: Track Forecast Issue Identity Independently of Localized Copy

**Files:**
- Modify: `Tests/CodexRadarTests/DashboardStoreForecastTests.swift`
- Modify: `Sources/CodexRadar/Stores/DashboardStore.swift`

**Interfaces:**
- Consumes: `issues: [String]` and `AppLanguage.defaultsKey`.
- Produces: private `forecastIssue: String?` semantic slot used by refresh, replacement, and removal paths.

- [ ] **Step 1: Write the failing cross-language lifecycle test**

Add to `DashboardStoreForecastTests`:

```swift
@MainActor
@Test
func replacesAndClearsForecastIssueAcrossLanguageChanges() async {
  let defaults = UserDefaults.standard
  let previousLanguage = defaults.object(forKey: AppLanguage.defaultsKey)
  defer {
    if let previousLanguage {
      defaults.set(previousLanguage, forKey: AppLanguage.defaultsKey)
    } else {
      defaults.removeObject(forKey: AppLanguage.defaultsKey)
    }
  }

  let fetcher = ForecastResultQueue([
    .failure(ResetForecastServiceError.invalidResponse),
    .failure(ResetForecastServiceError.invalidResponse),
    .success(.notModified),
  ])
  let store = makeStore(fetch: { try await fetcher.fetch(etag: $0) })

  defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
  await store.refreshForecast()
  let englishIssue = store.issues.first
  #expect(store.issues.count == 1)

  defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.defaultsKey)
  await store.refreshForecast()
  #expect(store.issues.count == 1)
  #expect(store.issues.first != englishIssue)

  await store.refreshForecast()
  #expect(store.issues.isEmpty)
}
```

- [ ] **Step 2: Verify the issue test is RED**

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter replacesAndClearsForecastIssueAcrossLanguageChanges
```

Expected: FAIL because the English issue survives the Chinese failure and recovery.

- [ ] **Step 3: Implement the forecast issue slot**

Add:

```swift
private var forecastIssue: String?
```

Replace issue cleanup at the start of `refresh(generation:)`:

```swift
issues = forecastIssue.map { [$0] } ?? []
```

Delete `forecastIssuePrefix` and replace the helpers:

```swift
private func removeForecastIssue() {
  guard let forecastIssue else { return }
  issues.removeAll { $0 == forecastIssue }
  self.forecastIssue = nil
}

private func setForecastIssue(error: Error) {
  removeForecastIssue()
  let message = error as? ResetForecastServiceError == .notInitialized
    ? AppLocalization.string("Reset monitoring is starting up.")
    : AppLocalization.string("Reset monitoring is temporarily unavailable.")
  let issue = String(
    format: AppLocalization.string("Reset forecast: %@"),
    message
  )
  forecastIssue = issue
  issues.append(issue)
}
```

- [ ] **Step 4: Verify the store suite is GREEN**

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter DashboardStoreForecastTests
```

Expected: PASS; the issue count remains one after the language-changing failure and becomes zero after recovery.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/CodexRadar/Stores/DashboardStore.swift Tests/CodexRadarTests/DashboardStoreForecastTests.swift
git commit -m "fix: track forecast issues by source"
```

### Task 3: Verify, Publish, and Close Review Threads

**Files:**
- Verify only: all Swift sources and tests.
- GitHub: `tangwz/codex-radar` PR #1 review threads.

**Interfaces:**
- Consumes: commits from Tasks 1 and 2.
- Produces: pushed branch, explanatory replies, and zero unresolved review threads.

- [ ] **Step 1: Run formatting and whitespace checks**

```bash
swift-format lint --recursive Sources Tests
git diff --check origin/codex/tibo-monitoring-client...HEAD
```

Expected: both commands exit zero. If `swift-format` is unavailable, record that limitation and run the whitespace check plus the full suite.

- [ ] **Step 2: Run the complete Swift suite**

```bash
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: all suites and tests PASS.

- [ ] **Step 3: Confirm scope and push**

```bash
git status --short --branch
git log --oneline origin/codex/tibo-monitoring-client..HEAD
git push origin codex/tibo-monitoring-client
```

Expected: only the design, plan, and two focused fixes are ahead before push; push succeeds.

- [ ] **Step 4: Reply to rejected duplicate threads**

Use the GitHub review reply API on comments `3599836356` and `3599836357`. Explain that lifecycle transitions receive new server-issued `signal_id` values and that server `stale` is authoritative across clients. Reference reducer and Swift regression tests.

- [ ] **Step 5: Reply to fixed threads**

Use the GitHub review reply API on comments `3599836358` and `3599836361`. State that baseline persistence now follows successful delivery, not-modified responses retry observation, and forecast issue identity is independent of localized copy. Include focused and full-suite test results.

- [ ] **Step 6: Resolve and verify all addressed threads**

Resolve only after replies and verification:

- `PRRT_kwDOTYbuls6RoI7V`
- `PRRT_kwDOTYbuls6RoI7W`
- `PRRT_kwDOTYbuls6RoI7X`
- `PRRT_kwDOTYbuls6RoI7Y`

Then run from the public worktree:

```bash
python3 /Users/tangwz/.codex/plugins/cache/openai-curated-remote/github/0.1.8-2841cf9749ae/skills/gh-address-comments/scripts/fetch_comments.py > /tmp/codex-radar-pr-1-comments-final.json
```

Expected: PR #1 reports zero unresolved review threads.

---

## Completion Criteria

- Failed or unauthorized delivery does not advance the persisted baseline.
- A not-modified response retries observation without duplicating an already delivered signal.
- Switching languages cannot leave or duplicate forecast issues.
- Signal ID and stale remain server-authoritative.
- Full Swift suite passes.
- Branch is pushed and all four latest review threads are replied to and resolved.
