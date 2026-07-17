# Codex Radar

Codex Radar 是一个以菜单栏为主要入口的 macOS 应用，用于查看 Codex reset 状态与本地 token 用量，并管理应用偏好。

## Language

**Menu Bar Panel**:
点击菜单栏图标后出现的紧凑状态与操作面板。
_Avoid_: Popup, 弹窗

**Settings Window**:
承载 Dashboard、Settings 和 About 三个同级页面的独立应用窗口。
_Avoid_: Preferences Window, Dashboard Window

**Dashboard**:
展示 Codex reset 状态和本地 token 用量的只读页面。
_Avoid_: Home, Overview

**Settings**:
管理语言、外观和 reset 提醒偏好的页面。
_Avoid_: General, General Settings

**About**:
展示应用身份、版本、外部链接和版权信息的页面。
_Avoid_: Info

**App Version**:
应用包中的发布版本与构建号。打包脚本是唯一写入来源，应用界面只读取生成后的 `Info.plist`；首个版本为 `0.1.0 (1)`。
_Avoid_: UI Version, Runtime Version Constant
