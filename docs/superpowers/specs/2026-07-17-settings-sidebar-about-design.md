# 设置侧边栏与 About 页面设计

## 目标

将 Codex Radar 现有的独立 Dashboard 窗口和单页设置表单整合为一个标准 macOS Settings 窗口。窗口采用固定侧边栏，包含“仪表盘”“通用”“关于”三个页面；菜单栏弹窗删除仪表盘入口，并新增可直接定位到 About 页的“关于 Codex Radar”入口。

About 页参考 CodexBar 当前的分组 Form 结构，显示应用图标、名称、版本、外部链接和版权信息。本次只展示版本，不引入自动更新。

## 已确认范围

- 设置窗口侧边栏固定包含：仪表盘、通用、关于。
- 现有 `ContentView` 作为仪表盘详情页复用，不改变 Dashboard 的业务逻辑、数据源或刷新行为。
- 菜单栏弹窗的应用操作顺序调整为：立即检查、设置…、关于 Codex Radar、退出。
- 删除菜单栏中的仪表盘入口及 Command-D 快捷键。
- “设置…”和 Command-, 每次都将设置窗口定位到“通用”。
- “关于 Codex Radar”每次都将同一个设置窗口定位到“关于”。
- About 页显示版本 `0.1.0 (1)`，版本与构建号从应用包的 `Info.plist` 读取。
- About 页包含 GitHub、个人网站、X 和 Bilibili，不包含电子邮件。
- 页脚显示 `© 2026 Terence Tang. All rights reserved.`。

## 参考实现与取舍

CodexBar 当前使用原生 SwiftUI `Settings` scene，并以 `SettingsPane` 和独立选择状态驱动页面切换。其侧边栏当前采用固定宽度的 `List` 配合 `HStack`，而非 `NavigationSplitView`。CodexBar 曾使用 `NavigationSplitView`，但后续为避免侧边栏折叠和宽度不稳定，改为显式的固定布局。

Codex Radar 采用相同的固定侧边栏方向，但不复制 CodexBar 的通知和隐藏窗口兼容层。CodexBar 的菜单主体由 AppKit 管理，因此需要借助通知进入 SwiftUI 环境调用 `openSettings`；Codex Radar 的 `MenuBarView` 本身是 SwiftUI，可直接使用环境中的 `openSettings`。

## 架构

### 页面模型

新增内部 `SettingsPane` 枚举，固定包含：

1. `dashboard`
2. `general`
3. `about`

每个页面提供本地化标题。侧边栏顺序与枚举定义保持一致，并通过测试固定该顺序。

### 选择状态

新增仅运行时存在的 `SettingsSelection`，负责持有当前 `SettingsPane`：

- 初始值为 `general`。
- 菜单“设置…”先设置为 `general`，再打开 Settings scene。
- 菜单“关于 Codex Radar”先设置为 `about`，再打开 Settings scene。
- 侧边栏直接绑定同一选择状态。
- 不将页面选择写入 `UserDefaults`，避免持久化状态覆盖入口要求的明确路由。

### 应用状态

应用继续只创建一个 `DashboardStore`，并将其同时传给 `MenuBarView` 和 Settings scene 内的仪表盘。`DashboardStore.startMonitoring()` 已具备幂等保护，因此菜单栏和仪表盘先后出现不会创建重复监控任务。

删除独立的 `Window("Codex Radar", id: "dashboard")` scene。应用启动后不再需要查找并隐藏 Dashboard 窗口，相关兼容逻辑一并删除。应用继续使用 accessory activation policy，不显示 Dock 图标。

## 设置窗口布局

设置窗口采用固定侧边栏与详情区组成的水平布局：

- 侧边栏固定为 `220pt` 宽，使用 `List` 的 sidebar 样式。
- 仪表盘使用图表类 SF Symbol。
- 通用使用齿轮 SF Symbol。
- 关于优先使用应用图标；图标不可用时使用信息类 SF Symbol。
- 侧边栏与详情区之间使用系统分隔线。
- 默认窗口大小为 `1000 × 720pt`。
- 最小窗口大小为 `980 × 620pt`，同时容纳 `220pt` 的侧边栏和现有最小宽度为 `760pt` 的仪表盘。
- 窗口允许在不裁切仪表盘核心内容的范围内缩放。

详情区根据 `SettingsSelection` 切换：

- `dashboard`：复用现有 `ContentView`，保留刷新按钮、图表、加载状态和错误提示。
- `general`：保留现有语言、外观和重置提醒设置，改为适应详情区宽度的分组 Form，不再固定整个窗口为 `440 × 220pt`。
- `about`：显示新的 About 页面。

## About 页面

About 页使用分组 Form，并包含以下区域。

### 应用信息

- `92 × 92pt` 应用图标。
- 应用名称 `Codex Radar`。
- 版本文本 `Version 0.1.0 (1)`；“Version”需要本地化。
- English 简介为 `Track Codex reset signals and local token usage.`。
- 简体中文简介为 `追踪 Codex 重置信号和本地 token 用量。`。

应用图标不可用时显示 SF Symbol 占位，不影响其他内容。

### 链接

链接按以下顺序显示：

1. GitHub：`https://github.com/tangwz/codex-radar`
2. Website：`https://codex-radar.tangwz.com`
3. X：`https://x.com/shixtang`
4. Bilibili：`https://space.bilibili.com/19041535`

每行包含固定宽度图标、标题、外链箭头和整行点击区域。点击后使用 `NSWorkspace` 交给系统默认浏览器，不在应用内嵌网页。外链箭头可在 hover 时使用强调色，但链接行仍遵循系统 Light/Dark Mode 语义色。

### 版权

链接区页脚居中显示：

`© 2026 Terence Tang. All rights reserved.`

## 版本元数据

`script/build_and_run.sh` 在生成应用包 `Info.plist` 时写入：

- `CFBundleShortVersionString`：`0.1.0`
- `CFBundleVersion`：`1`
- `NSHumanReadableCopyright`：`© 2026 Terence Tang. All rights reserved.`

新增独立 `AppMetadata` 从 Bundle 读取并格式化版本，避免 SwiftUI 视图直接散落 plist key。格式化规则固定为：

- 版本和构建号都存在：`0.1.0 (1)`。
- 只有版本存在：`0.1.0`。
- 版本缺失：`—`，即使构建号存在也不单独显示。

开发环境直接运行未打包二进制且元数据缺失时显示 `Version —`，不得崩溃。

## 菜单行为

`MenuActionID` 调整为以下顺序：

1. `refresh`
2. `settings`
3. `about`
4. `quit`

行为约束：

- `refresh` 保持现有刷新、禁用和进度状态。
- `settings` 设置选择状态为 `general`，打开 Settings scene，并激活应用；保留 Command-,。
- `about` 设置选择状态为 `about`，打开同一个 Settings scene，并激活应用；不增加快捷键。
- `quit` 保持 Command-Q 和现有终止行为。
- 删除 `dashboard` action、Command-D 和 `openWindow(id: "dashboard")`。

## 本地化

English 与简体中文资源至少补充：

- Dashboard / 仪表盘
- About / 关于
- About Codex Radar / 关于 Codex Radar
- Version %@ / 版本 %@
- Links / 链接
- Website / 网站
- Bilibili / Bilibili
- About 简介

品牌名称、URL 和版权文本不翻译。

## 容错

- 缺少应用图标时使用 SF Symbol 占位。
- 缺少 Bundle 版本字段时显示破折号，不使用强制解包。
- 外链使用应用内预定义且经过测试的 URL；系统浏览器负责网络错误和页面加载结果。
- Settings scene 已打开时，新的入口只更新页面选择并复用现有窗口，不创建第二个设置窗口。

## 测试与验证

### 自动化测试

- 更新 `MenuActionLayoutTests`，约束菜单操作顺序为 `refresh`、`settings`、`about`、`quit`，并确认不再包含 dashboard。
- 新增设置导航测试，覆盖默认 `general`、显式选择 `about` 以及三个固定页面的顺序。
- 新增 `AppMetadata` 测试：
  - 完整信息格式化为 `0.1.0 (1)`。
  - 缺失版本或构建号时按约定规则安全降级。
  - 四个链接的名称、顺序和 URL 正确。
- 保持现有 Dashboard、扫描、通知和主题测试不变。

### 构建与人工验收

运行：

```bash
swift test
./script/build_and_run.sh
plutil -p dist/CodexRadar.app/Contents/Info.plist
```

检查：

- 应用包包含版本 `0.1.0`、构建号 `1` 和版权信息。
- 菜单栏弹窗不再显示仪表盘入口。
- Command-, 和“设置…”打开同一个设置窗口并定位“通用”。
- “关于 Codex Radar”打开同一个窗口并定位“关于”。
- 侧边栏三个页面切换稳定，窗口缩放时仪表盘不裁切。
- About 页版本文本、四个外链和版权信息正确。
- 四个外链均由默认浏览器打开。
- English、简体中文、Light Mode 和 Dark Mode 显示正常。

## 非目标

本次不包含：

- 自动更新、更新渠道或检查更新按钮。
- 构建日期或 Git commit 展示。
- 电子邮件链接。
- 页面选择持久化。
- Dashboard 业务逻辑、数据源、token 扫描、reset 预测或通知行为调整。
- 与本功能无关的窗口或视觉重构。
