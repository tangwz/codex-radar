# App Appearance Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent System Default, Light, and Dark appearance picker that immediately updates every Codex Radar scene.

**Architecture:** Model appearance as a small raw-value enum that owns persistence metadata, safe decoding, and `ColorScheme?` mapping. Keep one `@AppStorage` source in the app scene and apply its resolved preference to the dashboard, menu bar content, menu bar label, and settings; the settings view writes the same key directly.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SwiftPM, macOS 14+

## Global Constraints

- Default to System Default and recover unknown stored values as System Default.
- Apply one appearance preference to the menu bar, dashboard, and settings window.
- Update immediately without restarting the app or rebuilding `DashboardStore`.
- Preserve the existing dark palette, menu bar icon, business behavior, and language preference.
- Support English and Simplified Chinese.

---

### Task 1: Appearance Preference Model

**Files:**
- Create: `Sources/CodexRadar/Models/AppAppearance.swift`
- Create: `Tests/CodexRadarTests/AppAppearanceTests.swift`

**Interfaces:**
- Consumes: persisted raw strings and SwiftUI `ColorScheme`.
- Produces: `AppAppearance.defaultsKey`, `AppAppearance.resolve(_:)`, and `AppAppearance.colorScheme`.

- [ ] **Step 1: Write the failing appearance mapping tests**

Create `Tests/CodexRadarTests/AppAppearanceTests.swift`:

```swift
import SwiftUI
import Testing

@testable import CodexRadar

struct AppAppearanceTests {
  @Test
  func mapsStoredValuesToPreferredColorSchemes() {
    #expect(AppAppearance.resolve("system").colorScheme == nil)
    #expect(AppAppearance.resolve("light").colorScheme == .light)
    #expect(AppAppearance.resolve("dark").colorScheme == .dark)
  }

  @Test
  func fallsBackToSystemForUnknownStoredValue() {
    #expect(AppAppearance.resolve("corrupted") == .system)
  }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter AppAppearanceTests
```

Expected: compilation fails because `AppAppearance` does not exist.

- [ ] **Step 3: Implement the minimal appearance model**

Create `Sources/CodexRadar/Models/AppAppearance.swift`:

```swift
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  static let defaultsKey = "appAppearance"

  var id: Self { self }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  static func resolve(_ storedValue: String) -> AppAppearance {
    AppAppearance(rawValue: storedValue) ?? .system
  }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2.

Expected: both `AppAppearanceTests` pass.

- [ ] **Step 5: Commit the model and tests**

```bash
git add Sources/CodexRadar/Models/AppAppearance.swift Tests/CodexRadarTests/AppAppearanceTests.swift
git commit -m "feat: add app appearance preference"
```

---

### Task 2: Settings and Scene Integration

**Files:**
- Modify: `Sources/CodexRadar/App/CodexRadarApp.swift`
- Modify: `Sources/CodexRadar/Views/SettingsView.swift`
- Modify: `Sources/CodexRadar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `AppAppearance.defaultsKey` and `AppAppearance.resolve(_:)` from Task 1.
- Produces: one app-wide `preferredColorScheme` and a localized three-option settings picker.

- [ ] **Step 1: Add the settings picker**

In `SettingsView`, add:

```swift
@AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue
```

Place this picker after Language:

```swift
Picker("Appearance", selection: $appearance) {
  Text("System Default").tag(AppAppearance.system.rawValue)
  Text("Light").tag(AppAppearance.light.rawValue)
  Text("Dark").tag(AppAppearance.dark.rawValue)
}
```

Increase the form frame height from `180` to `220`.

- [ ] **Step 2: Resolve one preference in the app scene**

In `CodexRadarApp`, add:

```swift
@AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system.rawValue

private var preferredColorScheme: ColorScheme? {
  AppAppearance.resolve(appearance).colorScheme
}
```

Apply `.preferredColorScheme(preferredColorScheme)` to `dashboardContent`, `MenuBarView`, `MenuBarLabel`, and `SettingsView` after their locale environment modifier.

- [ ] **Step 3: Add English and Simplified Chinese strings**

Add to `en.lproj/Localizable.strings`:

```text
"Appearance" = "Appearance";
"Light" = "Light";
"Dark" = "Dark";
```

Add to `zh-Hans.lproj/Localizable.strings`:

```text
"Appearance" = "外观";
"Light" = "浅色";
"Dark" = "深色";
```

- [ ] **Step 4: Run the complete build and test suite**

Run:

```bash
swift build
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Expected: the build succeeds and all tests pass.

- [ ] **Step 5: Launch and verify persistence and live switching**

Run:

```bash
./script/build_and_run.sh --verify
pgrep -fl CodexRadar
```

Open Settings and switch System Default → Light → Dark while macOS is in Dark Mode. Confirm the settings window and menu popup change immediately, the dashboard uses the same preference, and relaunching the app preserves the final selection.

- [ ] **Step 6: Commit the integration**

```bash
git add \
  Sources/CodexRadar/App/CodexRadarApp.swift \
  Sources/CodexRadar/Views/SettingsView.swift \
  Sources/CodexRadar/Resources/en.lproj/Localizable.strings \
  Sources/CodexRadar/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat: add appearance settings"
```
