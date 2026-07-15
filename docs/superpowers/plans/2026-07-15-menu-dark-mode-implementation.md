# Menu Dark Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved graphite shell and cobalt forecast card for the menu bar's Dark Mode while preserving the current Light Mode and all existing behavior.

**Architecture:** Add a focused `MenuBarTheme` value that maps `ColorScheme` to semantic presentation decisions and dark color tokens. Pass one resolved theme through the existing menu bar subviews, keeping business state in `DashboardStore` unchanged and preserving the current light rendering branches verbatim.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SwiftPM, macOS 14+

## Global Constraints

- Apply the redesign only to the menu bar popup in Dark Mode.
- Preserve the existing Light Mode rendering.
- Preserve menu width, component order, text, keyboard shortcuts, links, notification state, and red alert semantics.
- Keep the implementation SwiftUI-native and scoped to `MenuBarView`.
- Maintain readable contrast with Reduce Transparency enabled.

---

### Task 1: Semantic Menu Bar Theme

**Files:**
- Create: `Sources/CodexRadar/Views/MenuBarTheme.swift`
- Create: `Tests/CodexRadarTests/MenuBarThemeTests.swift`

**Interfaces:**
- Consumes: SwiftUI `ColorScheme`.
- Produces: `MenuBarTheme.init(colorScheme:)`, `MenuBarTheme.mode`, `MenuBarTheme.forecastEmphasis`, `MenuBarTheme.actionPresentation`, and dark-only semantic color tokens.

- [ ] **Step 1: Write the failing theme-selection tests**

Create `Tests/CodexRadarTests/MenuBarThemeTests.swift`:

```swift
import SwiftUI
import Testing

@testable import CodexRadar

struct MenuBarThemeTests {
  @Test
  func selectsGraphiteCobaltPresentationInDarkMode() {
    let theme = MenuBarTheme(colorScheme: .dark)

    #expect(theme.mode == .graphiteCobalt)
    #expect(theme.forecastEmphasis == .cobalt)
    #expect(theme.actionPresentation == .insetGroup)
  }

  @Test
  func preservesSystemPresentationInLightMode() {
    let theme = MenuBarTheme(colorScheme: .light)

    #expect(theme.mode == .system)
    #expect(theme.forecastEmphasis == .systemAccent)
    #expect(theme.actionPresentation == .plain)
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
  --filter MenuBarThemeTests
```

Expected: compilation fails because `MenuBarTheme` does not exist.

- [ ] **Step 3: Implement the semantic theme**

Create `Sources/CodexRadar/Views/MenuBarTheme.swift`:

```swift
import SwiftUI

enum MenuBarThemeMode: Equatable {
  case system
  case graphiteCobalt
}

enum MenuBarForecastEmphasis: Equatable {
  case systemAccent
  case cobalt
}

enum MenuBarActionPresentation: Equatable {
  case plain
  case insetGroup
}

struct MenuBarTheme {
  let mode: MenuBarThemeMode

  init(colorScheme: ColorScheme) {
    mode = colorScheme == .dark ? .graphiteCobalt : .system
  }

  var isDarkRedesign: Bool { mode == .graphiteCobalt }

  var forecastEmphasis: MenuBarForecastEmphasis {
    isDarkRedesign ? .cobalt : .systemAccent
  }

  var actionPresentation: MenuBarActionPresentation {
    isDarkRedesign ? .insetGroup : .plain
  }

  let panelBackground = Color(red: 23.0 / 255.0, green: 27.0 / 255.0, blue: 34.0 / 255.0)
  let elevatedSurface = Color(red: 32.0 / 255.0, green: 37.0 / 255.0, blue: 45.0 / 255.0)
  let insetSurface = Color(red: 27.0 / 255.0, green: 32.0 / 255.0, blue: 40.0 / 255.0)
  let cobaltStart = Color(red: 10.0 / 255.0, green: 58.0 / 255.0, blue: 157.0 / 255.0)
  let cobaltEnd = Color(red: 8.0 / 255.0, green: 124.0 / 255.0, blue: 255.0 / 255.0)
  let darkPrimaryText = Color.white
  let darkSecondaryText = Color.white.opacity(0.68)
  let darkTertiaryText = Color.white.opacity(0.38)
  let darkHairline = Color.white.opacity(0.09)
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2.

Expected: both `MenuBarThemeTests` pass.

- [ ] **Step 5: Commit the semantic theme**

```bash
git add Sources/CodexRadar/Views/MenuBarTheme.swift Tests/CodexRadarTests/MenuBarThemeTests.swift
git commit -m "feat: add menu bar dark theme"
```

---

### Task 2: Apply the Approved Dark Presentation

**Files:**
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift`
- Test: `Tests/CodexRadarTests/MenuBarThemeTests.swift`

**Interfaces:**
- Consumes: `MenuBarTheme(colorScheme:)` from Task 1 and existing `DashboardStore`, `ResetForecast`, and menu action APIs.
- Produces: Dark-only graphite container, cobalt prediction card, elevated metric cards, inset action group, and unchanged Light Mode branches.

- [ ] **Step 1: Resolve and pass one theme from the root menu view**

Add `@Environment(\.colorScheme) private var colorScheme` and resolve:

```swift
private var theme: MenuBarTheme {
  MenuBarTheme(colorScheme: colorScheme)
}
```

Pass `theme` into `MenuResetPredictionCard`, `MenuMetric`, and `MenuActionRow`. Add the Dark Mode panel background without changing the existing width or padding:

```swift
.background(theme.isDarkRedesign ? theme.panelBackground : .clear)
```

- [ ] **Step 2: Apply the cobalt forecast card without changing its content states**

Keep the current Light Mode fill and border. For Dark Mode use:

```swift
LinearGradient(
  colors: [theme.cobaltStart, theme.cobaltEnd],
  startPoint: .topLeading,
  endPoint: .bottomTrailing
)
```

Use `theme.darkPrimaryText` for primary content, `theme.darkSecondaryText` for supporting content, a white low-opacity inner hairline, and a short blue-black shadow. Pass the theme to `RadarLogo`, `ResetStatusBadge`, and `PredictionSourceChip`; preserve red styling when `forecast.isActive` is true.

- [ ] **Step 3: Apply elevated metric cards and the inset action group**

For Dark Mode:

```swift
.background(
  theme.elevatedSurface,
  in: RoundedRectangle(cornerRadius: 10, style: .continuous)
)
.overlay {
  RoundedRectangle(cornerRadius: 10, style: .continuous)
    .strokeBorder(theme.darkHairline, lineWidth: 1)
}
```

Wrap the existing action loop in a Dark Mode inset surface, add hairline separators between rows, and change hover feedback to `Color.white.opacity(0.07)`. Keep the current plain Light Mode group and existing keyboard shortcuts.

- [ ] **Step 4: Build and run the full test suite**

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

- [ ] **Step 5: Launch and visually verify both appearances**

Run:

```bash
./script/build_and_run.sh --verify
pgrep -fl CodexRadar
```

In Dark Mode verify the graphite shell, cobalt forecast card, elevated metrics, inset action group, readable secondary text, hover feedback, and red alert state. In Light Mode verify the existing appearance remains unchanged. Capture the Dark Mode menu popup for comparison with the approved mockup.

- [ ] **Step 6: Commit the presentation**

```bash
git add Sources/CodexRadar/Views/MenuBarView.swift
git commit -m "feat: redesign menu dark mode"
```
