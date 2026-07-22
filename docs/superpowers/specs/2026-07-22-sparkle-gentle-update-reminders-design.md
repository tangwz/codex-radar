# Sparkle 温和更新提醒设计

## 背景

CodexRadar 是使用 `.accessory` activation policy 的后台菜单栏应用。现有自动更新实现通过 `SPUStandardUpdaterController` 提供 Sparkle 标准检查、下载、安装和错误界面，同时把 `userDriverDelegate` 留空。

Sparkle 2.9.4 会对启用定时更新检查、但没有声明并实现 gentle scheduled update reminders 的后台应用记录警告。该警告不阻止更新检查，但说明后台发现更新时缺少一条足够温和、可被用户注意并重新聚焦更新窗口的交互路径。

本设计只补齐这条提醒路径，不改变已经批准的自动更新信任模型、发布流程、appcast、签名、下载或安装机制。

## 参考实现与对齐边界

主要产品参考是 `steipete/CodexBar` 在提交 `cc8da27cec92029a6435bfee4a703a719290234e` 的实现：

- 由长生命周期对象持有 `SPUStandardUpdaterController`；
- 使用 `SPUUpdaterDelegate`；
- 自动检查和自动下载由同一个用户设置同步控制；
- 用户主动检查继续使用 Sparkle 标准窗口；
- 下载和安装仍由 Sparkle 管理；
- 下载完成后可通过应用菜单触发立即安装。

CodexBar 当前仍将 `userDriverDelegate` 设为 `nil`，没有实现 gentle-reminder delegate。CodexRadar 不照抄这一缺口，而是保持上述主路径不变，仅增加 Sparkle 2.9.4 后台应用警告所要求的最小提醒桥接。

提醒行为参考 Sparkle 官方的 Background App, Dock, and Notification Example，但只采用其中的 Notification Center 部分。CodexRadar 不临时切换为 `.regular` activation policy、不创建 Dock 图标，也不添加 Dock badge。

## 目标

- 消除 Sparkle 的 gentle-reminders 警告，并提供真实而非声明式的提醒能力。
- 后台定时检查发现更新时发送一条 macOS 本地通知。
- 用户点击通知后，将 Sparkle 已存在的标准更新窗口带到前台。
- 用户已经关注更新或更新会话结束时移除提醒。
- 通知不可用时，Sparkle 标准更新窗口仍是完整兜底。
- 保持 CodexBar 的标准 Sparkle 更新路径，避免引入自定义 updater 状态机或安装逻辑。

## 非目标

- 自定义更新窗口、下载器、安装器或权限提升逻辑。
- 修改 release workflow、appcast、Ed25519 签名或 immutable release 协议。
- 修改自动检查、自动下载或更新频道设置。
- 临时显示 Dock 图标或 Dock badge。
- 在本任务中增加 CodexBar 的“Update ready, restart now?”菜单项；该能力可作为独立对齐任务评估，不能与警告修复耦合。
- 用通知替代 Sparkle 标准更新窗口。

## 方案选择

`SparkleUpdaterController` 同时实现 `SPUStandardUserDriverDelegate`，并作为 `SPUStandardUpdaterController` 的 `userDriverDelegate`。

该 delegate 声明 `supportsGentleScheduledUpdateReminders = true`，同时实现实际提醒行为：

- 不覆盖 `standardUserDriverShouldHandleShowingScheduledUpdate`，或者显式返回 `true`；
- 因此 Sparkle 始终继续负责展示标准更新窗口；
- 在 `standardUserDriverWillHandleShowingUpdate` 中，只为非用户发起的更新会话发送本地通知；
- 点击通知时再次调用标准 updater 的检查入口，使 Sparkle 把已存在的更新窗口带到前台。

不采用 notification-only 方案，因为通知可能未获授权、未送达或未被用户看到。也不采用自定义菜单状态机方案，因为它会扩大状态同步、可访问性和生命周期测试范围，超出本次警告修复所需的最小改动。

## 产品行为

### 用户主动检查

- About 页面的“检查更新…”继续调用现有 user-driven check。
- Sparkle 标准窗口展示更新、无更新或错误结果。
- 不发送本地更新提醒，避免用户主动操作后收到重复通知。

### 后台定时检查

- Sparkle 继续按照自己的调度策略检查更新。
- 发现更新时，Sparkle 继续准备并展示标准更新窗口；CodexRadar 不拦截或替换该窗口。
- 同时发送一条本地通知，标题说明有新版本可用，正文包含 `displayVersionString`。
- 通知使用稳定 identifier。新的提醒替换旧提醒，不按检查次数累积通知。

### 点击通知

- 只处理稳定 identifier 对应通知的默认点击动作。
- 点击后直接调用 updater 的展示入口，让 Sparkle 聚焦现有更新窗口；若应用在通知点击前已终止，则由重新启动后的 updater 发起新的标准检查。
- 该入口不能被 About 页面用于控制按钮状态的 `canCheckForUpdates` guard 阻断，因为已有更新会话时该状态可能暂时为 `false`。
- 其他通知，包括 reset forecast 通知，保持原有行为。

### 提醒清理

以下任一事件发生时，移除相同 identifier 的 pending 和 delivered notification：

- `standardUserDriverDidReceiveUserAttentionForUpdate`；
- `standardUserDriverWillFinishUpdateSession`。

这覆盖用户查看、安装、跳过、关闭更新以及更新会话因错误终止的生命周期。清理操作应具有幂等性。

## 应用架构

### `SparkleUpdaterController`

- 继续是 Sparkle integration 的唯一所有者。
- 在现有 `SPUUpdaterDelegate` 之外实现 `SPUStandardUserDriverDelegate`。
- 将 `SPUStandardUpdaterController` 的 `userDriverDelegate` 从 `nil` 改为 `self`。
- 仅根据 `SPUUserUpdateState.userInitiated` 决定是否请求发送提醒。
- 不持有第二套更新状态，不解析 appcast，也不直接控制下载或安装。

### `UpdateReminderNotificationService`

新增一个轻量、主线程隔离的通知组件，职责限定为：

- 查询当前通知授权状态；
- 使用稳定 identifier 投递更新提醒；
- 移除 pending 和 delivered reminder；
- 暴露 identifier 匹配逻辑供 `AppDelegate` 路由点击事件；
- 通过可注入闭包或窄协议支持无真实 Notification Center 的单元测试。

该组件不主动请求权限。CodexRadar 已通过 reset notification 流程请求通知权限，本功能复用现有授权结果，避免第二套权限弹窗和授权状态缓存。

### `AppDelegate`

- 继续作为 `UNUserNotificationCenterDelegate`。
- 新增 notification response 回调，只识别更新提醒的稳定 identifier 和 `UNNotificationDefaultActionIdentifier`。
- 匹配后通过 `UpdaterSettingsModel` 的专用提醒入口调用底层 updater。
- 不匹配时不执行更新操作。

### `UpdaterSettingsModel`

- 保留现有 About 页面 `checkForUpdates()` 行为和 `canCheckForUpdates` guard。
- 新增仅供通知点击路由使用的内部入口；它验证 provider 可用后直接调用 provider 的标准检查方法，不使用 UI guard。
- 不向 SwiftUI 页面暴露新的用户设置或状态。

## 本地化

新增 English 和简体中文字符串：

- 更新可用通知标题；
- 包含目标版本号的通知正文。

通知文本使用现有 `AppLocalization` 和用户选择的应用语言，不从系统通知设置另建语言来源。

## 权限、失败与日志

- 授权状态为 `.authorized` 或 `.provisional` 时才投递通知。
- `.denied`、`.notDetermined` 或其他不可投递状态直接跳过，不在发现更新时突然请求权限。
- Notification Center 投递失败只记录不含 feed 内容的诊断日志。
- 通知投递或清理失败不得取消、跳过或中止 Sparkle 更新会话。
- Sparkle feed、网络、签名和安装错误继续由现有 updater delegate 和标准 UI 处理。
- 应用继续保持 `.accessory` activation policy。

## 测试策略

### 单元测试

- 用户主动更新会话不请求发送提醒。
- 后台定时更新会话请求发送一次提醒。
- 稳定 identifier 防止多条更新提醒累积。
- 通知点击仅在 identifier 和默认动作同时匹配时调用 updater。
- 通知点击使用专用 updater 入口，即使 `canCheckForUpdates == false` 也能请求聚焦现有会话。
- 用户关注更新时清除提醒。
- 更新会话结束时清除提醒。
- 重复清理不产生额外状态或错误。
- 未授权和投递失败不影响 updater 调用路径。
- reset forecast 等非更新通知不会触发更新检查。

### 构建与静态验证

- SwiftPM build 和现有 test suite 通过。
- 最终 release app 仍包含既有 Sparkle 安全配置。
- 新增 delegate 后 updater 的所有权和生命周期不发生弱引用提前释放。

### 手工验证

使用真实菜单栏应用和可控的签名测试 feed，分别验证：

1. 删除或调整 `SULastCheckTime`，覆盖 near-launch 和延迟后台检查。
2. 用户主动检查时只出现 Sparkle 标准反馈，不出现本地更新通知。
3. 后台发现更新时出现单条通知，Sparkle 标准窗口仍存在。
4. 点击通知后更新窗口进入前台。
5. 查看、跳过或结束更新会话后通知消失。
6. 禁止通知权限后，更新检查和 Sparkle 标准窗口仍正常工作。
7. Console 不再出现 background app does not implement gentle reminders 警告。

完整端到端验证仍依赖一个高于当前安装版本、具有有效 feed signature 和 archive signature 的测试发布。没有可用签名 feed 时只能完成构建、单元测试和无更新路径验证，不能宣称自动更新端到端可用。

## 验收标准

- `userDriverDelegate` 不再为 `nil`，并有与声明匹配的真实 gentle reminder 实现。
- Sparkle gentle-reminders 警告在正式 app 启动和后台调度检查中消失。
- 后台发现更新会发送至多一条本地提醒。
- 用户主动检查不会产生重复提醒。
- 点击提醒可以带回 Sparkle 标准更新窗口。
- 更新会话获得用户关注或结束后提醒被清除。
- 通知权限拒绝或 Notification Center 失败不会破坏更新流程。
- 产品更新行为除上述提醒外继续与 CodexBar 的标准 Sparkle 路径保持一致。

## 参考资料

- CodexBar updater：<https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBar/CodexbarApp.swift>
- CodexBar update-ready menu：<https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBar/MenuDescriptor.swift>
- CodexBar Sparkle 文档：<https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/docs/sparkle.md>
- Sparkle Gentle Update Reminders：<https://sparkle-project.org/documentation/gentle-reminders/>
