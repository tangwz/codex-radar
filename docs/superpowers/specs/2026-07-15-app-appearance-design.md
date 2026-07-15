# 应用外观设置设计

## 目标

在设置窗口增加「跟随系统 / 浅色 / 深色」三态外观选项。选择后立即作用于菜单栏弹窗、仪表盘和设置窗口，并持久化到本地偏好；默认值为跟随系统。

## 数据模型

- 新增 `AppAppearance` 枚举，包含 `system`、`light`、`dark`。
- 使用稳定字符串作为持久化值，避免展示文案变化影响已有偏好。
- 使用独立的 `appAppearance` UserDefaults key，不与语言偏好耦合。
- `system` 映射到 `nil`，让 SwiftUI 继续读取 macOS 当前外观。
- `light` 映射到 `ColorScheme.light`，`dark` 映射到 `ColorScheme.dark`。
- 遇到未知或损坏的持久化值时回退到 `system`。

## 状态与场景

- `CodexRadarApp` 通过 `@AppStorage` 持有唯一的外观偏好源。
- 仪表盘、菜单栏内容、菜单栏 Label 和设置窗口均接收相同的 `.preferredColorScheme`。
- 切换设置时依赖 SwiftUI 状态传播立即更新，不重启应用、不重建业务 Store，也不触发 Token 扫描或预测刷新。
- 菜单栏 Icon 本身保持彩色资源，不因外观偏好切换资源。

## 设置界面

- 在现有语言 Picker 下方增加 `Appearance` Picker。
- 选项顺序固定为 `System Default`、`Light`、`Dark`。
- 沿用当前 grouped Form，不新增独立标签页或自定义控件。
- 适当增加设置窗口高度，保证语言、外观和重置提醒三项不拥挤。

## 国际化

- 英文新增 `Appearance`、`Light`、`Dark`。
- 简体中文对应为「外观」「浅色」「深色」。
- 复用已有 `System Default`，中文继续显示「跟随系统」。

## Dark Mode 集成

- 当偏好解析为 `.dark` 时，菜单栏使用已实现的石墨灰与钴蓝主题。
- 当偏好解析为 `.light` 时，即使系统为 Dark Mode，菜单栏也使用现有 Light Mode 分支。
- 当偏好为 `.system` 时，菜单栏继续随系统外观实时变化。

## 测试与验证

- 使用 TDD 覆盖三种持久化值到 `ColorScheme?` 的映射。
- 覆盖未知值回退到 `system`。
- 运行完整 SwiftPM 构建和测试。
- 在系统 Dark Mode 下依次切换三项，确认菜单栏、仪表盘和设置窗口立即同步。
- 重启 APP 后确认选择仍然保留。
- 检查中英文设置文案和布局。

## 非目标

- 不增加自动定时切换、自定义配色或独立菜单栏主题。
- 不修改现有 Dark Mode 颜色方案。
- 不改变通知、重置预测、Token 统计或快捷键行为。
