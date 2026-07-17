# Settings Sidebar and About Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Dashboard、Settings 和 About 页面整合进一个固定侧边栏 Settings 窗口，并让菜单入口定向打开 Settings 或 About 页面。

**Architecture:** 使用 `SettingsPane` 与内存态 `SettingsSelection` 驱动固定宽度 `List(.sidebar)` + `HStack` 详情布局。现有单例 `DashboardStore` 同时服务菜单和 Settings 中的 Dashboard；About 页面通过纯数据模型读取 Bundle 版本并提供经过测试的外链。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Package Manager、Swift Testing、macOS 14+

## Global Constraints

- 最低系统版本保持 macOS 14，不新增 Swift package 依赖。
- 侧边栏固定为 `220pt`；窗口默认 `1000 × 720pt`，最小 `980 × 620pt`。
- 窗口标题必须随当前页面和应用语言显示 `Dashboard`、`Settings` 或 `About`。
- Settings 页面固定按 `dashboard`、`settings`、`about` 排列，选择状态不持久化。
- 菜单操作固定按 `refresh`、`dashboard`、`settings`、`about`、`quit` 排列。
- 菜单显示文案固定为 `Refresh`、`Dashboard`、`Settings`、`About`、`Quit`，简体中文对应为 `刷新`、`仪表盘`、`设置`、`关于`、`退出`，不使用动作专属长标题或省略号。
- Dashboard 与 Command-D 强制选择 `dashboard`；“Settings”与 Command-, 强制选择 `settings`；“About”强制选择 `about`。
- About 版本从 `CFBundleShortVersionString` 和 `CFBundleVersion` 读取；首版为 `0.1.0 (1)`。
- About 只包含 GitHub、Website、X、Bilibili，不包含电子邮件、自动更新、构建日期或 Git commit。
- 版权固定为 `© 2026 Terence Tang. All rights reserved.`。
- 不改变 Dashboard 数据源、token 扫描、reset 预测、通知或刷新语义。
- 所有代码、标识符、注释和提交信息使用 English。

## File Map

- Create `Sources/CodexRadar/Models/SettingsPane.swift`: Settings 页面枚举和运行时选择状态。
- Create `Sources/CodexRadar/Support/AppMetadata.swift`: Bundle 版本格式化和 About 外链配置。
- Create `Sources/CodexRadar/Views/ApplicationIcon.swift`: About hero 与侧边栏复用的应用图标及占位视图。
- Create `Sources/CodexRadar/Views/AboutView.swift`: 分组 Form、hero、外链行和版权页脚。
- Modify `Sources/CodexRadar/Views/SettingsView.swift`: 固定侧边栏、详情路由和 Settings 页面。
- Modify `Sources/CodexRadar/Views/MenuBarView.swift`: 将 Dashboard action 改为统一窗口路由，并新增定向 Settings/About action。
- Modify `Sources/CodexRadar/App/CodexRadarApp.swift`: 删除独立 Dashboard scene，注入共享 store 与 selection。
- Modify `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`: About 与导航英文资源。
- Modify `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`: About 与导航简体中文资源。
- Modify `script/build_and_run.sh`: 写入版本、构建号与版权 plist 字段。
- Create `Tests/CodexRadarTests/SettingsNavigationTests.swift`: 页面顺序、默认选择和显式选择测试。
- Create `Tests/CodexRadarTests/AppMetadataTests.swift`: 版本降级和外链配置测试。
- Create `Tests/CodexRadarTests/SettingsLayoutTests.swift`: Settings 固定布局尺寸测试。
- Modify `Tests/CodexRadarTests/MenuActionLayoutTests.swift`: 新菜单顺序回归测试。

---

### Task 1: Settings Navigation Model

**Files:**
- Create: `Sources/CodexRadar/Models/SettingsPane.swift`
- Test: `Tests/CodexRadarTests/SettingsNavigationTests.swift`

**Interfaces:**
- Consumes: `ObservableObject` and `@Published` from Combine.
- Produces: `SettingsPane.allCases`, `SettingsPane.titleKey`, `SettingsPane.systemImage`, `SettingsSelection.init(pane:)`, `SettingsSelection.pane`, and `SettingsSelection.show(_:)`.

- [ ] **Step 1: Write the failing navigation tests**

Create `Tests/CodexRadarTests/SettingsNavigationTests.swift`:

```swift
import Testing

@testable import CodexRadar

@MainActor
struct SettingsNavigationTests {
  @Test
  func keepsTheSettingsPaneOrderStable() {
    #expect(SettingsPane.allCases == [.dashboard, .settings, .about])
  }

  @Test
  func startsOnSettingsAndSupportsExplicitRouting() {
    let selection = SettingsSelection()

    #expect(selection.pane == .settings)

    selection.show(.about)
    #expect(selection.pane == .about)

    selection.show(.dashboard)
    #expect(selection.pane == .dashboard)
  }

  @Test
  func providesStablePresentationMetadata() {
    #expect(SettingsPane.dashboard.titleKey == "Dashboard")
    #expect(SettingsPane.dashboard.systemImage == "chart.xyaxis.line")
    #expect(SettingsPane.settings.titleKey == "Settings")
    #expect(SettingsPane.settings.systemImage == "gearshape.fill")
    #expect(SettingsPane.about.titleKey == "About")
    #expect(SettingsPane.about.systemImage == "info.circle.fill")
  }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

Run:

```bash
swift test --filter SettingsNavigationTests
```

Expected: compilation fails because `SettingsPane` and `SettingsSelection` do not exist.

- [ ] **Step 3: Implement the minimal navigation model**

Create `Sources/CodexRadar/Models/SettingsPane.swift`:

```swift
import Combine

enum SettingsPane: String, CaseIterable, Hashable {
  case dashboard
  case settings
  case about

  var titleKey: String {
    switch self {
    case .dashboard: "Dashboard"
    case .settings: "Settings"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .dashboard: "chart.xyaxis.line"
    case .settings: "gearshape.fill"
    case .about: "info.circle.fill"
    }
  }
}

@MainActor
final class SettingsSelection: ObservableObject {
  @Published var pane: SettingsPane

  init(pane: SettingsPane = .settings) {
    self.pane = pane
  }

  func show(_ pane: SettingsPane) {
    self.pane = pane
  }
}
```

- [ ] **Step 4: Run the focused and full test suites**

Run:

```bash
swift test --filter SettingsNavigationTests
swift test
```

Expected: `SettingsNavigationTests` passes, followed by the full suite passing.

- [ ] **Step 5: Commit the navigation model**

```bash
git add Sources/CodexRadar/Models/SettingsPane.swift Tests/CodexRadarTests/SettingsNavigationTests.swift
git commit -m "feat: add settings navigation model"
```

---

### Task 2: About Metadata, Links, and Package Version

**Files:**
- Create: `Sources/CodexRadar/Support/AppMetadata.swift`
- Modify: `script/build_and_run.sh:4-7,38-68`
- Test: `Tests/CodexRadarTests/AppMetadataTests.swift`

**Interfaces:**
- Consumes: `Bundle.main.infoDictionary` and `URL` from Foundation.
- Produces: `AppMetadata.init(infoDictionary:)`, `AppMetadata.current`, `AppMetadata.versionString`, and `AboutLink.all`.

- [ ] **Step 1: Write the failing metadata and link tests**

Create `Tests/CodexRadarTests/AppMetadataTests.swift`:

```swift
import Testing

@testable import CodexRadar

struct AppMetadataTests {
  @Test
  func formatsVersionAndBuild() {
    let metadata = AppMetadata(
      infoDictionary: [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
      ]
    )

    #expect(metadata.versionString == "0.1.0 (1)")
  }

  @Test
  func degradesWhenVersionFieldsAreMissingOrEmpty() {
    #expect(
      AppMetadata(infoDictionary: ["CFBundleShortVersionString": "0.1.0"])
        .versionString == "0.1.0"
    )
    #expect(
      AppMetadata(infoDictionary: ["CFBundleVersion": "1"])
        .versionString == "—"
    )
    #expect(
      AppMetadata(infoDictionary: ["CFBundleShortVersionString": ""])
        .versionString == "—"
    )
    #expect(AppMetadata(infoDictionary: [:]).versionString == "—")
  }

  @Test
  func exposesTheApprovedLinksInOrder() {
    #expect(AboutLink.all.map(\.id) == [.github, .website, .x, .bilibili])
    #expect(
      AboutLink.all.map(\.url.absoluteString) == [
        "https://github.com/tangwz/codex-radar",
        "https://codex-radar.tangwz.com",
        "https://x.com/shixtang",
        "https://space.bilibili.com/19041535",
      ]
    )
    #expect(AboutLink.all.map(\.titleKey) == ["GitHub", "Website", "X", "Bilibili"])
  }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

Run:

```bash
swift test --filter AppMetadataTests
```

Expected: compilation fails because `AppMetadata` and `AboutLink` do not exist.

- [ ] **Step 3: Implement About metadata and link configuration**

Create `Sources/CodexRadar/Support/AppMetadata.swift`:

```swift
import Foundation

struct AppMetadata: Equatable, Sendable {
  let version: String?
  let build: String?

  init(infoDictionary: [String: Any]) {
    version = Self.nonEmptyString(infoDictionary["CFBundleShortVersionString"])
    build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
  }

  static var current: AppMetadata {
    AppMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])
  }

  var versionString: String {
    guard let version else { return "—" }
    guard let build else { return version }
    return "\(version) (\(build))"
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct AboutLink: Identifiable, Equatable, Sendable {
  enum ID: String, Sendable {
    case github
    case website
    case x
    case bilibili
  }

  let id: ID
  let titleKey: String
  let systemImage: String
  let url: URL

  static let all: [AboutLink] = [
    AboutLink(
      id: .github,
      titleKey: "GitHub",
      systemImage: "chevron.left.slash.chevron.right",
      url: makeURL("https://github.com/tangwz/codex-radar")
    ),
    AboutLink(
      id: .website,
      titleKey: "Website",
      systemImage: "globe",
      url: makeURL("https://codex-radar.tangwz.com")
    ),
    AboutLink(
      id: .x,
      titleKey: "X",
      systemImage: "bird",
      url: makeURL("https://x.com/shixtang")
    ),
    AboutLink(
      id: .bilibili,
      titleKey: "Bilibili",
      systemImage: "play.rectangle",
      url: makeURL("https://space.bilibili.com/19041535")
    ),
  ]

  private static func makeURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
      preconditionFailure("Invalid About URL: \(value)")
    }
    return url
  }
}
```

- [ ] **Step 4: Run the metadata tests**

Run:

```bash
swift test --filter AppMetadataTests
```

Expected: all `AppMetadataTests` pass.

- [ ] **Step 5: Add package version constants and plist fields**

Add these constants after `MIN_SYSTEM_VERSION` in `script/build_and_run.sh`:

```bash
MARKETING_VERSION="0.1.0"
BUILD_NUMBER="1"
COPYRIGHT="© 2026 Terence Tang. All rights reserved."
```

Add these keys after `CFBundlePackageType` in the generated plist:

```xml
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT</string>
```

- [ ] **Step 6: Verify the script and packaged metadata**

Run:

```bash
bash -n script/build_and_run.sh
./script/build_and_run.sh --verify
test "$(plutil -extract CFBundleShortVersionString raw dist/CodexRadar.app/Contents/Info.plist)" = "0.1.0"
test "$(plutil -extract CFBundleVersion raw dist/CodexRadar.app/Contents/Info.plist)" = "1"
test "$(plutil -extract NSHumanReadableCopyright raw dist/CodexRadar.app/Contents/Info.plist)" = "© 2026 Terence Tang. All rights reserved."
```

Expected: shell syntax is valid, the app bundle passes verification and stays running, and all three assertions exit successfully.

- [ ] **Step 7: Commit metadata and packaging**

```bash
git add Sources/CodexRadar/Support/AppMetadata.swift Tests/CodexRadarTests/AppMetadataTests.swift script/build_and_run.sh
git commit -m "feat: add about metadata and app version"
```

---

### Task 3: Unified Settings and About UI

**Files:**
- Create: `Sources/CodexRadar/Views/ApplicationIcon.swift`
- Create: `Sources/CodexRadar/Views/AboutView.swift`
- Modify: `Sources/CodexRadar/Views/SettingsView.swift:1-30`
- Modify: `Sources/CodexRadar/App/CodexRadarApp.swift:24-28,65-69`
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/CodexRadarTests/SettingsLayoutTests.swift`

**Interfaces:**
- Consumes: `SettingsPane`, `SettingsSelection`, `AppMetadata`, `AboutLink.all`, and the existing `ContentView(store:)`.
- Produces: `SettingsLayout` constants, `SettingsView.init(store:selection:)`, dynamic localized window titles, `AboutView.init(metadata:)`, and `ApplicationIcon.init(size:)`.

- [ ] **Step 1: Write the failing layout contract test**

Create `Tests/CodexRadarTests/SettingsLayoutTests.swift`:

```swift
import Testing

@testable import CodexRadar

struct SettingsLayoutTests {
  @Test
  func usesTheApprovedFixedDimensions() {
    #expect(SettingsLayout.sidebarWidth == 220)
    #expect(SettingsLayout.windowDefaultWidth == 1000)
    #expect(SettingsLayout.windowDefaultHeight == 720)
    #expect(SettingsLayout.windowMinWidth == 980)
    #expect(SettingsLayout.windowMinHeight == 620)
  }
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

Run:

```bash
swift test --filter SettingsLayoutTests
```

Expected: compilation fails because `SettingsLayout` does not exist.

- [ ] **Step 3: Add the reusable application icon**

Create `Sources/CodexRadar/Views/ApplicationIcon.swift`:

```swift
import AppKit
import SwiftUI

struct ApplicationIcon: View {
  let size: CGFloat

  var body: some View {
    Group {
      if let icon = NSApplication.shared.applicationIconImage {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "scope")
          .resizable()
          .scaledToFit()
          .padding(size * 0.18)
          .foregroundStyle(.accent)
          .background(.quaternary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    .accessibilityHidden(true)
  }
}
```

- [ ] **Step 4: Implement the grouped About form**

Create `Sources/CodexRadar/Views/AboutView.swift`:

```swift
import AppKit
import SwiftUI

struct AboutView: View {
  let metadata: AppMetadata

  init(metadata: AppMetadata = .current) {
    self.metadata = metadata
  }

  var body: some View {
    Form {
      Section {
        hero
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
      }

      Section {
        ForEach(AboutLink.all) { link in
          AboutLinkRow(link: link)
        }
      } header: {
        Text("Links")
      } footer: {
        Text("© 2026 Terence Tang. All rights reserved.")
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var hero: some View {
    VStack(spacing: 10) {
      ApplicationIcon(size: 92)

      VStack(spacing: 3) {
        Text("Codex Radar")
          .font(.title3.bold())
        Text(String(format: AppLocalization.string("Version %@"), metadata.versionString))
          .foregroundStyle(.secondary)
        Text("Track Codex reset signals and local token usage.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 8)
  }
}

private struct AboutLinkRow: View {
  let link: AboutLink
  @State private var isHovered = false

  var body: some View {
    Button {
      NSWorkspace.shared.open(link.url)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: link.systemImage)
          .frame(width: 18)
          .foregroundStyle(.secondary)
        Text(LocalizedStringKey(link.titleKey))
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption)
          .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}
```

- [ ] **Step 5: Replace the single-page Settings view with the fixed sidebar shell**

Replace `Sources/CodexRadar/Views/SettingsView.swift` with:

```swift
import AppKit
import SwiftUI

enum SettingsLayout {
  static let sidebarWidth: CGFloat = 220
  static let windowDefaultWidth: CGFloat = 1000
  static let windowDefaultHeight: CGFloat = 720
  static let windowMinWidth: CGFloat = 980
  static let windowMinHeight: CGFloat = 620
}

struct SettingsView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var selection: SettingsSelection

  var body: some View {
    HStack(spacing: 0) {
      SettingsSidebarView(selection: $selection.pane)
        .frame(width: SettingsLayout.sidebarWidth)
        .background {
          SettingsSidebarMaterial()
            .ignoresSafeArea()
        }

      Divider()
        .ignoresSafeArea()

      detailView
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(
      minWidth: SettingsLayout.windowMinWidth,
      idealWidth: SettingsLayout.windowDefaultWidth,
      maxWidth: .infinity,
      minHeight: SettingsLayout.windowMinHeight,
      idealHeight: SettingsLayout.windowDefaultHeight,
      maxHeight: .infinity
    )
    .background {
      SettingsWindowTitleBridge(title: AppLocalization.string(selection.pane.titleKey))
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  private var detailView: some View {
    switch selection.pane {
    case .dashboard:
      ContentView(store: store)
    case .settings:
      SettingsPageView()
    case .about:
      AboutView()
    }
  }
}

private struct SettingsSidebarView: View {
  @Binding var selection: SettingsPane

  var body: some View {
    List(selection: selectionBinding) {
      ForEach(SettingsPane.allCases, id: \.self) { pane in
        HStack(spacing: 9) {
          if pane == .about {
            ApplicationIcon(size: 22)
          } else {
            Image(systemName: pane.systemImage)
              .frame(width: 22)
              .foregroundStyle(.secondary)
          }

          Text(LocalizedStringKey(pane.titleKey))
        }
        .tag(pane)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
  }

  private var selectionBinding: Binding<SettingsPane?> {
    Binding(
      get: { selection },
      set: { newValue in
        if let newValue {
          selection = newValue
        }
      }
    )
  }
}

private struct SettingsPageView: View {
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  var body: some View {
    Form {
      Picker("Language", selection: $language) {
        Text("System Default").tag(AppLanguage.system.rawValue)
        Text("English").tag(AppLanguage.english.rawValue)
        Text("Simplified Chinese").tag(AppLanguage.simplifiedChinese.rawValue)
      }

      Picker("Appearance", selection: $appearance) {
        Text("System Default").tag(AppAppearance.system.rawValue)
        Text("Light").tag(AppAppearance.light.rawValue)
        Text("Dark").tag(AppAppearance.dark.rawValue)
      }

      LabeledContent("Reset alerts") {
        Text("Menu bar badge and notifications")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct SettingsSidebarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
  }
}

private struct SettingsWindowTitleBridge: NSViewRepresentable {
  let title: String

  func makeNSView(context: Context) -> SettingsWindowTitleView {
    let view = SettingsWindowTitleView()
    view.title = title
    return view
  }

  func updateNSView(_ nsView: SettingsWindowTitleView, context: Context) {
    nsView.title = title
  }
}

private final class SettingsWindowTitleView: NSView {
  var title = "" {
    didSet {
      applyTitle()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyTitle()
  }

  private func applyTitle() {
    window?.title = title
  }
}
```

- [ ] **Step 6: Add the exact localization entries**

Append these entries to the English resource:

```text
"Dashboard" = "Dashboard";
"Settings" = "Settings";
"About" = "About";
"Version %@" = "Version %@";
"Links" = "Links";
"GitHub" = "GitHub";
"Website" = "Website";
"X" = "X";
"Bilibili" = "Bilibili";
"Track Codex reset signals and local token usage." = "Track Codex reset signals and local token usage.";
```

向简体中文资源加入相同 key，并使用以下已确认值：

| Key | Simplified Chinese value |
| --- | --- |
| Dashboard | 仪表盘 |
| Settings | 设置 |
| About | 关于 |
| Version %@ | 版本 %@ |
| Links | 链接 |
| GitHub | GitHub |
| Website | 网站 |
| X | X |
| Bilibili | Bilibili |
| Track Codex reset signals and local token usage. | 追踪 Codex 重置信号和本地 token 用量。 |

Remove the now-unused action-specific localization keys `Open Dashboard`, `Check Now`, `Settings…`, and `Quit Codex Radar` from both resources. The menu reuses `Refresh`, `Dashboard`, `Settings`, `About`, and `Quit`.

- [ ] **Step 7: Inject the shared store and selection into the Settings scene**

Add the selection object immediately after the existing `DashboardStore` property in `CodexRadarApp`:

```swift
@StateObject private var settingsSelection = SettingsSelection()
```

Replace the existing Settings scene content with:

```swift
Settings {
  SettingsView(store: store, selection: settingsSelection)
    .environment(\.locale, selectedLocale)
    .preferredColorScheme(preferredColorScheme)
}
```

Keep the independent Dashboard window and menu action unchanged until Task 4. This intermediate wiring ensures the new required `SettingsView` initializer compiles while preserving current behavior.

- [ ] **Step 8: Run focused and full tests**

Run:

```bash
swift test --filter SettingsLayoutTests
swift test
swift build
```

Expected: the layout contract test passes, the full suite passes, and the application target compiles with the new required `SettingsView` initializer.

- [ ] **Step 9: Commit the unified Settings UI**

```bash
git add Sources/CodexRadar/Views/ApplicationIcon.swift Sources/CodexRadar/Views/AboutView.swift Sources/CodexRadar/Views/SettingsView.swift Sources/CodexRadar/App/CodexRadarApp.swift Sources/CodexRadar/Resources/en.lproj/Localizable.strings Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings Tests/CodexRadarTests/SettingsLayoutTests.swift
git commit -m "feat: add settings sidebar and about page"
```

---

### Task 4: Menu Routing and App Scene Integration

**Files:**
- Modify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift:6-11`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift:4-132`
- Modify: `Sources/CodexRadar/App/CodexRadarApp.swift:5-70`

**Interfaces:**
- Consumes: `SettingsSelection.show(_:)`, SwiftUI `openSettings`, `SettingsView.init(store:selection:)`, and the existing shared `DashboardStore`.
- Produces: menu order `[.refresh, .dashboard, .settings, .about, .quit]`, direct Dashboard/Settings/About routing, and one Settings scene containing all pages.

- [ ] **Step 1: Update the menu-order test first**

Replace the first test in `Tests/CodexRadarTests/MenuActionLayoutTests.swift` with:

```swift
@Test
func keepsOnlyApplicationActionsInTheMenuList() {
  #expect(MenuActionID.allCases == [.refresh, .dashboard, .settings, .about, .quit])
  #expect(MenuActionID.applicationActions == MenuActionID.allCases)
}
```

- [ ] **Step 2: Run the focused test and verify the red state**

Run:

```bash
swift test --filter MenuActionLayoutTests.keepsOnlyApplicationActionsInTheMenuList
```

Expected: compilation fails because `MenuActionID.about` does not exist and the action order differs.

- [ ] **Step 3: Change the menu action model and dependencies**

Replace the top declarations in `Sources/CodexRadar/Views/MenuBarView.swift` with:

```swift
import AppKit
import SwiftUI

enum MenuActionID: String, CaseIterable, Hashable {
  case refresh
  case dashboard
  case settings
  case about
  case quit

  static let applicationActions = MenuActionID.allCases
}

struct MenuBarView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var settingsSelection: SettingsSelection
  @Environment(\.openSettings) private var openSettings
  @Environment(\.colorScheme) private var colorScheme
```

Keep the existing theme, metrics, body, and monitoring logic unchanged.

- [ ] **Step 4: Replace the action switch with explicit Settings routing**

Replace `actionControl(_:)` and add `showSettings(_:)` immediately below it:

```swift
@ViewBuilder
private func actionControl(_ action: MenuActionID) -> some View {
  switch action {
  case .refresh:
    Button {
      Task { await store.refresh() }
    } label: {
      MenuActionRow(
        title: "Refresh",
        systemImage: "arrow.clockwise",
        shortcut: "⌘R",
        isLoading: store.isRefreshing,
        theme: theme
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut("r", modifiers: .command)
    .disabled(store.isRefreshing)

  case .dashboard:
    Button {
      showSettings(.dashboard)
    } label: {
      MenuActionRow(
        title: "Dashboard",
        systemImage: "rectangle.grid.2x2",
        shortcut: "⌘D",
        theme: theme
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut("d", modifiers: .command)

  case .settings:
    Button {
      showSettings(.settings)
    } label: {
      MenuActionRow(
        title: "Settings",
        systemImage: "gearshape",
        shortcut: "⌘,",
        theme: theme
      )
    }
    .buttonStyle(.plain)
    .keyboardShortcut(",", modifiers: .command)

  case .about:
    Button {
      showSettings(.about)
    } label: {
      MenuActionRow(
        title: "About",
        systemImage: "info.circle",
        theme: theme
      )
    }
    .buttonStyle(.plain)

  case .quit:
    Button {
      NSApplication.shared.terminate(nil)
    } label: {
      MenuActionRow(title: "Quit", systemImage: "power", shortcut: "⌘Q", theme: theme)
    }
    .buttonStyle(.plain)
    .keyboardShortcut("q", modifiers: .command)
  }
}

private func showSettings(_ pane: SettingsPane) {
  settingsSelection.show(pane)
  openSettings()
  NSApp.activate(ignoringOtherApps: true)
}
```

- [ ] **Step 5: Replace the app scene wiring**

Replace `Sources/CodexRadar/App/CodexRadarApp.swift` with:

```swift
import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    UNUserNotificationCenter.current().delegate = self
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

@main
struct CodexRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore()
  @StateObject private var settingsSelection = SettingsSelection()
  @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
  @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

  private var selectedLocale: Locale {
    AppLanguage(rawValue: language)?.locale ?? .current
  }

  private var preferredColorScheme: ColorScheme? {
    AppAppearance.resolve(appearance).colorScheme
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(store: store, settingsSelection: settingsSelection)
        .environment(\.locale, selectedLocale)
        .preferredColorScheme(preferredColorScheme)
    } label: {
      MenuBarLabel(
        hasResetAlert: ResetForecastPresentation(forecast: store.forecast).hasResetAlert
      )
      .environment(\.locale, selectedLocale)
      .preferredColorScheme(preferredColorScheme)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(store: store, selection: settingsSelection)
        .environment(\.locale, selectedLocale)
        .preferredColorScheme(preferredColorScheme)
    }
    .defaultSize(width: 1000, height: 720)
    .windowResizability(.contentMinSize)
  }
}
```

- [ ] **Step 6: Run focused and full automated verification**

Run:

```bash
swift test --filter MenuActionLayoutTests
swift test
swift build
```

Expected: the menu tests pass with the new order, the full suite passes, and the application builds without warnings introduced by this feature.

- [ ] **Step 7: Verify the packaged app and Info.plist**

Run:

```bash
./script/build_and_run.sh --verify
plutil -p dist/CodexRadar.app/Contents/Info.plist
```

Expected: verification succeeds; output includes `CFBundleShortVersionString = 0.1.0`, `CFBundleVersion = 1`, and the approved copyright.

- [ ] **Step 8: Perform manual UI acceptance**

Check all of the following in the packaged app:

1. The menu action order is Refresh, Dashboard, Settings, About, Quit.
2. Dashboard and Command-D open one Settings window on Dashboard every time.
3. Command-, and Settings open the same Settings window on Settings every time.
4. About opens the same Settings window on About every time.
5. The sidebar order is Dashboard, Settings, About; selecting Dashboard shows the existing forecast and token views.
6. The window title follows Dashboard, Settings, and About, including after an app-language change.
7. The Settings window opens at `1000 × 720pt`, does not shrink below `980 × 620pt`, and does not clip Dashboard content.
8. About shows the application icon, `Version 0.1.0 (1)`, the approved tagline, four links, and copyright.
9. Each link opens the approved URL in the default browser.
10. English, Simplified Chinese, Light Mode, and Dark Mode render correctly.
11. Relaunching the app does not restore a persisted page; menu entry routing remains authoritative.

- [ ] **Step 9: Commit menu and scene integration**

```bash
git add Sources/CodexRadar/Views/MenuBarView.swift Sources/CodexRadar/App/CodexRadarApp.swift Tests/CodexRadarTests/MenuActionLayoutTests.swift
git commit -m "feat: route menu actions into settings"
```

- [ ] **Step 10: Confirm the worktree is clean**

Run:

```bash
git status --short
```

Expected: no tracked implementation changes remain. Pre-existing untracked `.codex/` content may remain and must not be added.
