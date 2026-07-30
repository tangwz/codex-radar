# 仪表盘刷新入口与设置窗口一致性设计

## 背景

仪表盘、设置和关于共用同一个 SwiftUI `Settings` scene。仪表盘当前通过
`ContentView.toolbar` 提供刷新按钮，而另外两个页面没有 toolbar。

即使窗口使用紧凑统一工具栏样式，切换页面时 SwiftUI 仍会动态安装或卸载
`NSToolbar`。窗口 frame 保持 `1000 × 720pt`，但内容布局高度会在以下状态间变化：

- 设置和关于：没有 toolbar，`contentLayoutRect` 高度为 `688pt`；
- 仪表盘：存在一个 toolbar item，`contentLayoutRect` 高度为 `680pt`。

这会在“设置 → 仪表盘”等切换路径上产生可见的 `8pt` 内容跳动。

## 目标

- 三个页面切换时保持相同的窗口标题栏和内容布局高度。
- 刷新按钮只在仪表盘页面显示。
- 保留 Command-R 快捷键。
- 保留现有刷新语义：同时触发 reset history 与 dashboard 数据刷新。
- 保留刷新期间的禁用状态和现有 loading overlay。

## 非目标

- 不修改 DashboardStore、ResetHistoryStore 或数据请求行为。
- 不改变设置和关于页面内容。
- 不重新设计仪表盘卡片、统计图表或侧边栏。
- 不改变窗口默认尺寸和最小尺寸。

## 设计

### 页面内刷新入口

移除 `ContentView` 的 `.toolbar` modifier。刷新按钮改为仪表盘滚动内容中的首个控制行：

- 控制行位于仪表盘内容顶部、右对齐；
- 按钮同时显示刷新图标和本地化文本，使用标准 macOS bordered button 外观；
- 按钮与后续卡片保持明确但紧凑的垂直间距；
- 按钮继续绑定 Command-R；
- `store.isRefreshing` 为 true 时按钮禁用。

按钮 action 保持现有顺序：

1. 同步调用 `historyStore.refresh(timeZone:)`；
2. 创建 Task 并等待 `store.refresh()`。

### 窗口配置

移除 `SettingsWindowTitleView` 中仅用于修正 toolbar 展示方式的
`window.toolbarStyle = .unifiedCompact`。

窗口标题桥接继续只负责根据当前选项卡和语言更新 `window.title`。由于三个页面都不再向
Settings scene 注入 toolbar，切换页面时 `window.toolbar` 始终为 nil，
`contentLayoutRect` 高度保持不变。

## 错误与状态处理

刷新行为不新增错误通道。现有 Store 继续负责：

- 发布刷新状态；
- 收集 forecast、history 与 token usage 问题；
- 控制 loading overlay；
- 合并重叠请求。

页面内按钮只反映 `DashboardStore.isRefreshing`，与当前 toolbar 按钮行为一致。

## 验证

### 自动测试

- 运行完整 Swift 测试套件，确保刷新、路由、窗口桥接和 Store 行为不回归。

### 运行时验证

在同一个设置窗口中依次切换“设置 → 仪表盘 → 关于 → 仪表盘”，确认：

- 三个页面的窗口 frame 保持一致；
- 三个页面的 `contentLayoutRect` 高度一致；
- 三个页面下 `window.toolbar` 始终为 nil；
- 仪表盘页面顶部显示刷新按钮，其他页面不显示；
- 点击按钮与 Command-R 都触发刷新；
- 刷新期间按钮禁用，完成后恢复。

## 影响范围

- `Sources/CodexRadar/Views/ContentView.swift`
- `Sources/CodexRadar/Views/SettingsView.swift`

不涉及公共 API、持久化格式、网络协议或发布流程。
