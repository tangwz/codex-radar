# 菜单栏 Template Radar 图标设计

## 目标

将 Codex Radar 当前的彩色菜单栏图标替换为符合 macOS 菜单栏视觉规范的单色线稿图标。新图标采用已确认的 Radar Outline 方向：保留外环、内环、中心点和指向右上方的扫描线，同时由系统根据菜单栏外观自动着色。

改动仅作用于菜单栏状态项。应用程序图标、About 页面中的应用图标和安装包图标均保持不变。

## 当前实现

`MenuBarIconConfiguration` 从 SwiftPM resource bundle 加载 `MenuBarIcon.png`，将其缩放为 `18×18pt`。`MenuBarStatusIconRenderer` 在需要 reset 提醒时，把红点与彩色图标合成为一张非 template `NSImage`。

这种实现保留了完整的应用图标视觉，但菜单栏中会显示带蓝色方形底板的彩色图标，与周围由系统着色的单色线稿图标不一致。继续使用合成位图也会阻止图标自动适配浅色、深色、菜单栏着色和按钮高亮状态。

## 方案比较

### 采用 AppKit 矢量路径生成 template image

在代码中使用 AppKit 路径绘制 Radar Outline，将结果标记为 template image。路径使用逻辑坐标定义，由 AppKit 在目标显示比例下栅格化。

优点：

- 保持已确认的 Radar Outline 造型，不依赖近似的 SF Symbol。
- 在 Retina 和非 Retina 显示比例下保持清晰。
- 线宽、圆环和扫描线可以通过少量显式常量精确维护。
- 不需要继续打包仅供菜单栏使用的彩色 PNG。

缺点：

- 需要维护一小段绘制代码。
- 单元测试只能稳定验证尺寸、template 语义和控制器状态；最终视觉仍需人工检查。

### 使用单色 PNG 并标记为 template image

继续加载图片资源，但把资源替换为透明背景的单色线稿，并设置 template 属性。

优点是改动较小。缺点是资源需要额外管理，高分辨率源图仍会在运行时缩放，线宽调整也需要重新生成二进制资源。该方案不作为推荐方案。

### 使用现有 SF Symbol

使用 `scope` 等系统图标可获得完整的原生适配能力，但无法准确表达已确认的圆环、中心点和扫描线组合，也会削弱 Codex Radar 的识别性。该方案不采用。

## 最终设计

### Radar Outline 图形

`MenuBarIconConfiguration` 继续拥有菜单栏图标的尺寸和创建入口，但不再加载 `MenuBarIcon.png`。它以 `18×18pt` 画布生成以下元素：

- 一个构成主体边界的外环；
- 一个同心内环；
- 一个实心中心点；
- 一条从中心指向右上方的扫描线；
- 使用圆角线帽和一致线宽，确保在菜单栏尺寸下与相邻系统图标协调。

生成的 `NSImage` 标记为 template image。正常状态下，`NSStatusBarButton` 直接显示该图像，由 AppKit 决定前景色及高亮渲染。

图形只表达菜单栏状态项，不复用或修改应用程序图标资源。

### Reset 提示点

template image 不能在保持系统自动着色的同时包含固定红色区域，因此不再把红点合成到 `NSImage`。

`MenuBarController` 在安装状态项时，为 `NSStatusBarButton` 添加一个不参与 hit testing 的小型 badge view：

- badge 使用 `systemRed`；
- 固定在图标右上区域；
- `hasResetAlert` 为 `true` 时显示，否则隐藏；
- 状态变化只更新 badge 可见性，不重新创建状态项或覆盖 template image；
- badge 不拦截左键、右键或 Control-left-click。

这使雷达线稿继续由系统着色，同时保留现有 reset 提示的红色语义。

### 生命周期与状态更新

状态项安装时：

1. 创建唯一的 `NSStatusItem` 和 status button；
2. 设置 Radar Outline template image；
3. 创建并安装唯一的 badge view；
4. 订阅 forecast 和用户设置变化；
5. 根据当前 forecast 更新 badge 可见性和无障碍标签。

forecast 变化时只更新 badge 与无障碍标签。卸载时仍由现有控制器移除整个状态项，badge 随按钮一起释放，不增加独立的全局生命周期。

图标由静态路径和非可失败的 `NSImage` 绘制入口生成，不再依赖 bundle 资源查找，因此没有运行时资源缺失分支。路径参数错误属于开发期视觉缺陷，由单元测试和人工检查发现，不在运行时静默切换到另一种造型。

## 影响范围

- `Sources/CodexRadar/Views/MenuBarView.swift`
  - 将 `MenuBarIconConfiguration` 改为生成 Radar Outline template image。
- `Sources/CodexRadar/App/MenuBarController.swift`
  - 取消彩色图标与红点的位图合成；
  - 安装并更新独立的 reset badge view。
- `Sources/CodexRadar/Resources/MenuBarIcon.png`
  - 删除不再使用的彩色菜单栏资源。
- `Tests/CodexRadarTests/MenuActionLayoutTests.swift`
  - 更新图标配置测试，验证尺寸、template 属性和复用约定。
- `Tests/CodexRadarTests/MenuBarControllerTests.swift`
  - 验证 badge 只安装一次、不会拦截点击，并随 reset 状态显示或隐藏；
  - 保留左右键、popover、高亮与无障碍行为的现有回归测试。

以下文件明确不在改动范围内：

- `Sources/CodexRadar/Resources/AppIcon.png`
- `Sources/CodexRadar/Resources/AppIcon.icns`
- `Sources/CodexRadar/Views/ApplicationIcon.swift`
- 应用元数据、打包脚本和 About 页面

## 验证

自动验证：

- 运行菜单栏图标配置和控制器测试；
- 运行完整 SwiftPM test suite；
- 构建并验证本地应用包，确认已删除的菜单栏 PNG 不再被代码或打包结果依赖；
- 确认现有左键、右键、Control-left-click 和 popover highlight 测试继续通过。

人工验证：

- 在浅色和深色菜单栏下检查 Radar Outline 的清晰度和线宽；
- 检查菜单栏采用壁纸着色时图标仍跟随系统前景色；
- 打开面板时检查 status button 高亮状态；
- 分别检查 reset 提示点隐藏和显示状态；
- 确认 badge 不影响所有点击路径；
- 确认 Finder、Dock、About 页面和应用包仍显示原应用程序图标。

## 风险与控制

- 过细的线条可能在 18pt 下发虚。实现时使用对齐像素边界的逻辑坐标，并以实际菜单栏渲染结果作为最终判断。
- badge overlay 可能改变点击命中。badge view 必须明确忽略 hit testing，并由现有点击回归测试覆盖。
- controller 重复安装可能产生重复 badge。badge 应由单次 `install()` 生命周期创建，并增加数量断言。
- AppKit 外观切换不应触发手工重绘逻辑；依赖 template image 的系统渲染避免维护额外 appearance observer。

## 非目标

- 不修改应用程序图标及其任何展示位置。
- 不改变 reset 预测、通知、轮询或提醒判定逻辑。
- 不调整菜单面板内容、布局或主题。
- 不改变 `NSStatusItem + NSPopover` 架构和点击行为。
- 不引入新的用户设置或可选图标主题。
