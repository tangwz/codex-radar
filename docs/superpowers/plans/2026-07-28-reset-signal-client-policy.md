# Reset Signal 客户端策略实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 对 candidate、announced、completed 三类 reset 信号按 tweet ID 在单台客户端最多通知一次，并为所有非 stale 的可执行状态显示菜单栏红点。

**架构：** 通知资格继续由纯 policy 计算；新增小型 `ConsumedResetSignalStore` 负责本地持久去重；`ResetNotificationService` 只在实际投递成功后消费 ID。UI presentation 保持独立，直接根据当前 forecast 派生红点。

**技术栈：** Swift 6、Swift Package Manager、AppKit、UserNotifications、UserDefaults、Swift Testing、macOS 14。

## 全局约束

- 非 stale 的 candidate、announced、completed 均为 actionable。
- 同一 tweet ID 即使中间出现其他 ID 或 status 改变，也只能在单台客户端消费一次。
- 投递失败或通知权限拒绝不得消费 ID。
- 首次观察只建立 baseline，不补发历史通知。
- 不增加后端 callback 或 `notified_at`。
- 红点表示实时状态，不表示未读。
- announced 的 timing 文案与 completed 文案保持不变。
- 增加 English 与 Simplified Chinese candidate 本地化。
- 所有代码、注释、标识符、commit message 和代码块均使用 English。

---

## 文件边界

- `Sources/CodexRadar/Services/ConsumedResetSignalStore.swift`：排序数组持久化与旧 key 迁移。
- `Sources/CodexRadar/Services/ResetNotificationService.swift`：policy、candidate presentation、retry 与 store 集成。
- `Sources/CodexRadar/Models/ResetForecastPresentation.swift`：actionable red-dot projection。
- `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`：candidate 通知与通用 accessibility 文案。
- `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`：对应中文。
- `Sources/CodexRadar/App/MenuBarController.swift`：只调整 accessibility key。
- `Tests/CodexRadarTests/ConsumedResetSignalStoreTests.swift`：持久化、迁移、损坏恢复与 set semantics。
- `Tests/CodexRadarTests/ResetNotificationPolicyTests.swift`：candidate eligibility 与任意旧 ID 去重。
- `Tests/CodexRadarTests/ResetForecastPresentationTests.swift`：三种 actionable 红点。
- `Tests/CodexRadarTests/MenuBarControllerTests.swift`：badge 与 accessibility。
- `Tests/CodexRadarTests/AppLocalizationTests.swift`：本地化 key parity。

### Task 1: 安全持久化已消费 signal ID

**Files:**
- Create: `Sources/CodexRadar/Services/ConsumedResetSignalStore.swift`
- Create: `Tests/CodexRadarTests/ConsumedResetSignalStoreTests.swift`

**Interfaces:**
- Produces: `ConsumedResetSignalStore.hasBaseline`.
- Produces: `contains(_:)`, `establishBaseline(signalID:)`, `consume(_:)`.

- [ ] **Step 1: 编写失败的 store 测试**

覆盖稳定排序、任意旧 ID 查询、空 baseline、legacy migration、幂等 migration 与 corrupt data recovery。

```swift
@Test
func preservesEveryConsumedSignalID() throws {
  let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
  let store = ConsumedResetSignalStore(defaults: defaults)

  store.establishBaseline(signalID: "200")
  store.consume("100")
  store.consume("300")

  #expect(store.contains("100"))
  #expect(store.contains("200"))
  #expect(store.contains("300"))
}
```

- [ ] **Step 2: 运行测试并确认失败**

```bash
swift test --filter ConsumedResetSignalStoreTests
```

预期：store 不存在而 FAIL。

- [ ] **Step 3: 实现排序 JSON array 持久化**

使用：

```swift
private let baselineKey = "hasResetSignalBaseline"
private let consumedIDsKey = "consumedResetSignalIDs"
private let legacyLastIDKey = "lastObservedResetSignalID"
```

从 `[String]` decode 为 `Set<String>`，写入 `ids.sorted()`。首次访问时将 legacy ID 合入集合，只有新值成功写入后才删除旧 key。

- [ ] **Step 4: 实现保守损坏恢复**

新值无法 decode 时不崩溃：保留 baseline，从 legacy ID 恢复集合；`establishBaseline(signalID:)` 将当前 ID 视为已消费且不通知；使用 `Logger(subsystem: "com.terence.codex-radar", category: "reset-notifications")` 记录恢复，并覆写为合法排序数组。

- [ ] **Step 5: 验证并提交**

```bash
swift test --filter ConsumedResetSignalStoreTests
git add Sources/CodexRadar/Services/ConsumedResetSignalStore.swift Tests/CodexRadarTests/ConsumedResetSignalStoreTests.swift
git commit -m "feat: persist consumed reset signal IDs"
```

预期：PASS。

### Task 2: 通知 candidate 并按 set 去重

**Files:**
- Modify: `Sources/CodexRadar/Services/ResetNotificationService.swift`
- Modify: `Tests/CodexRadarTests/ResetNotificationPolicyTests.swift`

**Interfaces:**
- Consumes: `ConsumedResetSignalStore`.
- Produces: `ResetNotificationPolicy.decision(forecast:hasBaseline:consumedSignalIDs:)`.
- Produces: `ResetNotificationPresentation.Body.candidate`.

- [ ] **Step 1: 编写 set-based 失败测试**

将 candidate 加入 actionable 参数测试，并证明 A/B/A 不会再次通知：

```swift
@Test
func ignoresPreviouslyConsumedSignalAfterAnotherSignal() {
  let decision = ResetNotificationPolicy.decision(
    forecast: makeForecast(status: .candidate, signalID: "signal-a"),
    hasBaseline: true,
    consumedSignalIDs: ["signal-a", "signal-b"]
  )

  #expect(decision == .ignore)
}
```

增加 candidate delivery 失败后重试，以及成功后只消费一次的 service 测试。

- [ ] **Step 2: 运行测试并确认失败**

```bash
swift test --filter ResetNotificationPolicyTests
```

预期：旧 policy 只接受 `lastSignalID` 且排除 candidate，因此 FAIL。

- [ ] **Step 3: 修改纯 policy**

```swift
guard !forecast.stale,
  [.candidate, .announced, .completed].contains(forecast.status),
  let signalID = forecast.signalID,
  !consumedSignalIDs.contains(signalID)
else {
  return .ignore
}
```

首次观察仍返回 `.establishBaseline(forecast.signalID)`。

- [ ] **Step 4: 增加 candidate notification presentation**

`Body` 增加 `case candidate`。非 stale candidate 不依赖 timing，并生成：

```swift
content.title = AppLocalization.string("Possible Codex reset detected")
content.body = AppLocalization.string("A possible Codex reset signal was posted.")
```

- [ ] **Step 5: 集成 consumed store**

注入 `ConsumedResetSignalStore`。建立 baseline 时消费当前非空 ID 但不投递；delivery 返回 true 后才 `consume(signalID)`；失败时不改变集合。

- [ ] **Step 6: 验证并提交**

```bash
swift test --filter ResetNotificationPolicyTests
git add Sources/CodexRadar/Services/ResetNotificationService.swift Tests/CodexRadarTests/ResetNotificationPolicyTests.swift
git commit -m "feat: notify once for every reset signal status"
```

预期：PASS。

### Task 3: 扩展菜单栏红点

**Files:**
- Modify: `Sources/CodexRadar/Models/ResetForecastPresentation.swift`
- Modify: `Sources/CodexRadar/App/MenuBarController.swift`
- Modify: `Tests/CodexRadarTests/ResetForecastPresentationTests.swift`
- Modify: `Tests/CodexRadarTests/MenuBarControllerTests.swift`

**Interfaces:**
- Produces: candidate、announced、completed 的 `hasResetAlert`.
- Preserves: announced-only `timeDisplay`.

- [ ] **Step 1: 编写失败的 presentation/controller 测试**

```swift
@Test(arguments: [ResetStatus.candidate, .announced, .completed])
func showsAlertForEveryActionableStatus(_ status: ResetStatus) {
  let presentation = ResetForecastPresentation(
    forecast: makeForecast(status: status)
  )
  #expect(presentation.hasResetAlert)
}
```

同时证明 stale actionable 与 monitoring 隐藏 badge，打开 popover 不清除 badge。

- [ ] **Step 2: 运行测试并确认失败**

```bash
swift test --filter ResetForecastPresentationTests
swift test --filter MenuBarControllerTests
```

预期：candidate 与 completed 断言 FAIL。

- [ ] **Step 3: 实现 actionable projection**

```swift
private var isActionableStatus: Bool {
  status == .candidate || status == .announced || status == .completed
}

var hasResetAlert: Bool {
  !stale && isActionableStatus
}
```

不得读取 consumed notification ID。

- [ ] **Step 4: 泛化 accessibility key**

badge 可见时将 `"Codex reset incoming"` 改为 `"Codex reset signal detected"`；隐藏时继续使用 monitoring key。

- [ ] **Step 5: 验证并提交**

```bash
swift test --filter ResetForecastPresentationTests
swift test --filter MenuBarControllerTests
git add Sources/CodexRadar/Models/ResetForecastPresentation.swift Sources/CodexRadar/App/MenuBarController.swift Tests/CodexRadarTests/ResetForecastPresentationTests.swift Tests/CodexRadarTests/MenuBarControllerTests.swift
git commit -m "feat: show badge for actionable reset signals"
```

预期：PASS。

### Task 4: 本地化、完整验证与客户端 PR

**Files:**
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/CodexRadarTests/AppLocalizationTests.swift`
- Modify: `docs/superpowers/specs/2026-07-28-reset-signal-client-policy-design.md` only if implementation reveals a factual mismatch.

- [ ] **Step 1: 编写失败的本地化 parity 测试**

两个 table 都必须包含：

```text
Possible Codex reset detected
A possible Codex reset signal was posted.
Codex reset signal detected
```

- [ ] **Step 2: 运行测试并确认失败**

```bash
swift test --filter AppLocalizationTests
```

预期：三个 key 缺失而 FAIL。

- [ ] **Step 3: 增加 English strings**

```text
"Possible Codex reset detected" = "Possible Codex reset detected";
"A possible Codex reset signal was posted." = "A possible Codex reset signal was posted.";
"Codex reset signal detected" = "Codex reset signal detected";
```

- [ ] **Step 4: 增加 Simplified Chinese strings**

相同三个 key 依次使用：“可能检测到 Codex 重置”、“检测到一条可能的 Codex 重置信号。”、“检测到 Codex 重置信号”。key 与 source identifier 保持 English。

- [ ] **Step 5: 完整验证**

```bash
swift test
swift build
git diff --check
```

预期：全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/CodexRadar/Resources/en.lproj/Localizable.strings Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings Tests/CodexRadarTests/AppLocalizationTests.swift docs/superpowers/specs/2026-07-28-reset-signal-client-policy-design.md
git commit -m "feat: localize reset signal alerts"
```

- [ ] **Step 7: 创建客户端 PR**

push `codex/tibo-reset-signal-client`，向 `main` 创建非 draft PR。描述必须包含本地去重、baseline migration、retry、红点语义、验证命令和后端 PR 关系。
