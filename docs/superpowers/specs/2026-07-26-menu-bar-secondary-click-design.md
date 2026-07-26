# 菜单栏左右键统一交互设计

## 背景

Codex Radar 当前使用 SwiftUI `MenuBarExtra` 的 `.window` 样式展示 Menu Bar Panel。该入口只响应主点击，公开 API 没有 secondary-click 回调，因此右键点击菜单栏图标时不会打开面板。

本设计让左键、右键和 Control-左键拥有完全一致的 toggle 语义，同时保留现有 Menu Bar Panel 的内容、尺寸、主题和业务行为。

## 目标

- 面板关闭时，左键、右键和 Control-左键均打开同一个 Menu Bar Panel。
- 面板打开时，上述任一点击均关闭面板。
- 点击面板外部继续自动关闭面板。
- 不提供独立的右键菜单。
- 保留现有菜单栏图标、reset 红点、无障碍语义、语言和外观设置。
- 保留现有 Dashboard、Settings、About、Refresh、Quit 和快捷键行为。

## 方案比较

### 采用 `NSStatusItem` 与 `NSPopover`

由 AppKit 管理菜单栏入口和鼠标事件，使用一个 transient `NSPopover` 承载现有 SwiftUI `MenuBarView`。左键 target-action 与右键 click recognizer 汇合到同一个 toggle 动作。

该方案能够可靠区分鼠标按键，同时继续把面板内容留在 SwiftUI 中。代价是应用入口从纯 SwiftUI scene 变成小范围 AppKit 与 SwiftUI 混合架构。

### 采用 `NSStatusItem` 与 `NSMenu`

该方案与 CodexBar 类似，由 AppKit 原生菜单接管点击和展开行为，再用 `NSHostingView` 承载复杂内容。它天然适合由标准 `NSMenuItem` 组成的命令列表，但会把现有 `.window` 风格面板改成菜单跟踪模型。若继续保留动态卡片、进度动画和交互控件，就必须额外处理 custom menu item 的尺寸测量、tracking run loop、事件转发、刷新协调和 accessibility；menu tracking 期间的动态 resize 也不适合作为普通 SwiftUI layout 使用。

### 探测 `MenuBarExtra` 的私有视图层级

可以从嵌入 label 的 AppKit view 向上查找 SwiftUI 创建的内部 status button，并把右键转换为主点击。这能减少表面代码改动，但依赖未公开的 SwiftUI 视图层级和事件实现，系统升级后容易失效。

选择第一种方案。它满足交互要求，同时避免原生菜单带来的行为变化和私有实现依赖。

## 架构

新增主线程隔离的 `MenuBarController`，集中负责：

- 创建并持有唯一的 `NSStatusItem`。
- 配置菜单栏图标、reset 红点和本地化 accessibility label。
- 接收左键与右键事件，并统一调用 `togglePanel()`。
- 创建并持有 transient `NSPopover`。
- 把现有 `MenuBarView` 作为 SwiftUI root view 放入 popover。
- 在 popover 打开和关闭时同步 status button 的高亮状态。
- 在应用退出时释放 status item、popover、observation 和 event handler。

`CodexRadarApp` 不再声明 `MenuBarExtra` scene。应用仍使用现有 SwiftUI `Settings` scene；`AppDelegate` 在应用完成启动后安装 `MenuBarController`。`DashboardStore`、`SettingsSelection` 和 updater model 继续保持单例共享，不因为新入口产生第二份状态。

`NSPopover` 使用 transient behavior，并锚定在 status button 下方。面板内容继续保持 300pt 固定宽度；不复制 `MenuBarExtra` 的私有窗口实现，只依赖系统 popover 提供的定位、关闭和焦点行为。

## 可维护性边界

`MenuBarController` 是 AppKit presentation adapter，不是第二个 view model。它只拥有：

- `NSStatusItem`、`NSPopover`、hosting controller 和 gesture recognizer 等 AppKit 对象。
- status button 的图标与高亮等展示状态。
- 打开、关闭、锚定和清理面板的生命周期逻辑。
- 向应用 composition root 提供幂等的面板关闭能力。

`DashboardStore` 继续独占 forecast、token events、refresh 状态和 monitoring 生命周期；SwiftUI root view 继续从这些 observable models 直接派生内容。controller 可以观察 `hasResetAlert` 这类只用于 status item 展示的派生结果，但不得复制 forecast、token、refresh 或 action enablement 状态。

语言、外观和 Settings pane 仍由现有 `AppStorage` 与 `SettingsSelection` 持有。SwiftUI root wrapper 读取语言与外观，应用 composition root 更新 pane；controller 不持有这些值的可写副本。popover 的 `isShown` 是面板展示状态的唯一事实来源，不增加镜像 Boolean。

未来增加图表、筛选、账号切换、滚动内容或其他交互控件时，继续放在 SwiftUI 面板内部，不扩大 AppKit bridge。只有当产品明确把 Menu Bar Panel 收缩为完全由标准命令项组成的菜单时，才重新评估 `NSMenu`；不得通过不断增加 custom menu item glue 逐步把 controller 演化成菜单 UI 框架。

## 点击与面板状态

左键由 status button 的标准 target-action 触发。右键由只接受 secondary button 的 `NSClickGestureRecognizer` 触发；macOS 产生的 Control-左键沿 secondary-click 路径处理。两条事件路径不得包含各自的展示逻辑，只调用同一个 `togglePanel()`。

`togglePanel()` 只根据 popover 当前状态执行以下动作：

- `isShown == false`：锚定 status button 展示 popover，并高亮按钮。
- `isShown == true`：关闭 popover；关闭回调统一清除按钮高亮。

controller 提供幂等的 `dismissPanel()`：无论关闭来自 toggle、外部点击还是离开面板的 action，最终都通过 popover delegate 清除按钮高亮。不得假设 transient behavior 会在打开其他 menu、panel 或 window 时自动关闭。

不增加全局鼠标监听，不用双击执行额外动作，也不维护独立的“期望打开”状态。popover 是展示状态的唯一事实来源，避免事件与 UI 状态漂移。

## SwiftUI 面板与设置路由

现有 `MenuBarView`、action rows、forecast card 和 token metrics 保持不变。新增一个轻量 root wrapper，读取 `AppLanguage.defaultsKey` 和 `AppAppearance.defaultsKey`，向面板注入 locale 与 preferred color scheme，使已经创建的 popover 仍能实时响应设置变化。

`MenuBarView` 不再直接依赖 scene 提供的 `@Environment(\.openSettings)`，也不直接调用 `NSWorkspace` 或 `NSApp.terminate`。它接收一个窄的 `MenuBarPanelActions`，只暴露当前面板需要的外部动作：

- `openSource(URL)`
- `openSettings(SettingsPane)`
- `quit()`

`MenuBarPanelActions` 在应用 composition root 中组装：dismiss callback 来自 controller，URL、Settings 和 termination 副作用来自现有应用服务。controller 不解释 URL、pane 或业务动作。组合后的动作遵循统一顺序：

- Source URL：先 `dismissPanel()`，再用 `NSWorkspace` 打开 URL。
- Dashboard、Settings、About：先 `dismissPanel()`，再更新共享 `SettingsSelection`、激活应用并请求 SwiftUI `Settings` scene。
- Quit：先 `dismissPanel()`，再终止应用。
- Refresh：继续直接调用现有 `DashboardStore.refresh()`，保持面板打开并展示现有 progress 状态，不进入 `MenuBarPanelActions`。

由于 AppKit 承载的 hosting controller 不处于 `MenuBarExtra` scene 环境中，应用增加最小的 SwiftUI lifecycle bridge 来转发 typed `openSettings` 请求。AppKit `showPreferencesWindow:` action 只作为 bridge 不可用时的兼容回退，不能成为唯一设置入口。失败时记录错误，不回滚已经选择的 pane，也不创建自定义 Settings window。

任何外部路由失败后，popover 都保持关闭；不得为了恢复现场自动重新打开。这样可以避免 transient close 与异步路由结果竞争。

## 图标与状态更新

继续复用 `MenuBarIconConfiguration.image` 和现有 18pt 逻辑尺寸。AppKit 图标渲染层只负责把 reset 红点合成到 status button image，不改变 forecast 的 alert 判定规则。

`MenuBarController` 观察 `DashboardStore.forecast`，仅在 `hasResetAlert` 结果变化时重建 status image。普通状态与提醒状态都保持原始彩色渲染，不转换为 template image。accessibility label 根据当前提醒状态与应用语言更新。

## 错误处理与生命周期

- status button 创建失败时不创建 popover event handler，并记录不可恢复的入口错误。
- popover 展示前再次确认 status button 存在，避免使用已经释放的 anchor view。
- `dismissPanel()` 必须可重复调用，并允许 popover delegate 在所有关闭路径下执行同一清理逻辑。
- Source URL 打开失败时记录错误，popover 保持关闭。
- Settings bridge 未处理请求时尝试 AppKit fallback；两条路径都失败时记录错误并保持应用运行。
- controller 的安装必须幂等，避免 SwiftUI scene 更新或重复 lifecycle 回调创建多个菜单栏图标。
- `DashboardStore.startMonitoring()` 保持现有幂等语义，不引入第二个监控循环。

## 影响范围

- 应用入口：以 `MenuBarController` 替换 `MenuBarExtra`，并增加 Settings lifecycle bridge。
- Menu Bar Panel：只调整设置路由注入和外层环境包装，不改变面板内容。
- 图标：增加 AppKit 状态图标合成与 forecast observation。
- 文档：新增 ADR，记录为何为 secondary click 从 `MenuBarExtra` 转向 `NSStatusItem + NSPopover`。

本设计仅取代以下旧约束：`2026-07-15-menu-bar-icon-design.md` 和 `2026-07-15-menu-dark-mode-design.md` 中“不引入 AppKit `NSStatusItem`”的非目标。两份旧设计关于图标视觉、Dark Mode 和业务行为的其余决策继续有效。

`CONTEXT.md` 不需要修改；现有 **Menu Bar Panel** 已是准确的领域术语。

## 验证

### 自动测试

- 左键、右键和 Control-左键解析为同一个 toggle intent。
- 面板关闭时 toggle 产生 show command，打开时产生 close command。
- controller 重复安装不会创建第二个 status item。
- Source URL、Dashboard、Settings、About 和 Quit 的 action 顺序均为 dismiss 在前、外部副作用在后。
- Refresh 不调用 dismiss，并在 in-flight 期间继续通过 SwiftUI 状态更新 progress。
- 外部路由失败后不重新打开 popover。
- reset alert 状态切换会更新普通与红点图标，逻辑尺寸保持稳定。
- Settings pane 路由继续更新共享 selection。
- SwiftPM build 与现有测试全部通过。

### 人工验收

- 分别用左键、右键和 Control-左键打开及关闭面板。
- 点击面板外部后自动关闭，再次点击任一路径可正常打开。
- 验证 status button 的打开高亮和关闭复位。
- 验证 Refresh、Dashboard、Settings、About、Quit 及现有快捷键。
- 验证打开 Source URL、Dashboard、Settings 或 About 后原 popover 已关闭，不依赖获得焦点后的隐式关闭。
- 验证 English、简体中文、Light Mode、Dark Mode 和跟随系统设置。
- 验证普通图标、reset 红点与 accessibility label。
- 验证进程中只存在一个 Codex Radar 菜单栏图标。

## 非目标

- 不增加右键 context menu。
- 不把 Menu Bar Panel 改造成 `NSMenu`。
- 不调整 forecast、通知、token 扫描或更新机制。
- 不改变 Settings Window 的页面结构与尺寸。
- 不使用全局事件监听、私有 API 或 SwiftUI 私有视图层级探测。
- 不在 `MenuBarController` 中复制业务状态或实现 SwiftUI 内容布局。
- 不保证 `NSPopover` 的系统 chrome 与 `MenuBarExtra` 私有容器逐像素一致。
