# Menu Bar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the menu bar `scope` symbol with a full-bleed color radar asset that matches the application icon and preserves the existing reset alert dot.

**Architecture:** Add a dedicated transparent PNG optimized for the 18-point menu bar canvas instead of shrinking the padded application icon. Centralize the asset name and zero-inset geometry in `MenuBarIconConfiguration`, render it through SwiftUI with original colors, and package the SwiftPM resource bundle into the local `.app`.

**Tech Stack:** Swift 6, SwiftUI `MenuBarExtra`, Swift Testing, SwiftPM resources, macOS shell packaging

## Global Constraints

- Support macOS 14 or later.
- Preserve the existing reset alert state, red dot, and accessibility label.
- Keep the menu bar icon in original color rendering mode.
- Use an 18-by-18-point canvas with zero content inset.
- Do not change reset forecasting, notifications, menu actions, or the application icon.

---

### Task 1: Full-Bleed Menu Bar Radar Icon

**Files:**
- Create: `Sources/CodexRadar/Resources/MenuBarIcon.png`
- Modify: `Sources/CodexRadar/Views/MenuBarView.swift:282-299`
- Modify: `Tests/CodexRadarTests/MenuActionLayoutTests.swift`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Consumes: SwiftPM's generated `Bundle.module` resource bundle and the existing `MenuBarLabel(hasResetAlert:)` API.
- Produces: `MenuBarIconConfiguration.assetName: String`, `MenuBarIconConfiguration.sideLength: CGFloat`, `MenuBarIconConfiguration.contentInset: CGFloat`, and a `MenuBarIcon.png` resource.

- [ ] **Step 1: Write the failing layout and resource test**

Add the following test to `Tests/CodexRadarTests/MenuActionLayoutTests.swift`:

```swift
@Test
func usesAFullBleedColorMenuBarIcon() {
  #expect(MenuBarIconConfiguration.assetName == "MenuBarIcon")
  #expect(MenuBarIconConfiguration.sideLength == 18)
  #expect(MenuBarIconConfiguration.contentInset == 0)
  #expect(
    Bundle.module.url(
      forResource: MenuBarIconConfiguration.assetName,
      withExtension: "png"
    ) != nil
  )
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
  --filter MenuActionLayoutTests.usesAFullBleedColorMenuBarIcon
```

Expected: compilation fails because `MenuBarIconConfiguration` does not exist.

- [ ] **Step 3: Create the dedicated menu bar image**

Use `Sources/CodexRadar/Resources/AppIcon.png` as the visual reference. Generate an equivalent blue glass radar squircle on a flat chroma-key background, keep only a minimal removable perimeter, remove the chroma key with the installed imagegen helper, and save the alpha PNG as `Sources/CodexRadar/Resources/MenuBarIcon.png`.

Validate the resulting file with:

```bash
sips -g pixelWidth -g pixelHeight -g hasAlpha Sources/CodexRadar/Resources/MenuBarIcon.png
```

Expected: a square PNG with `hasAlpha: yes`, transparent corners, no white border, and the blue squircle occupying at least 95 percent of the canvas width and height.

- [ ] **Step 4: Add the minimal configuration and SwiftUI rendering**

Add above `MenuBarLabel` in `Sources/CodexRadar/Views/MenuBarView.swift`:

```swift
enum MenuBarIconConfiguration {
  static let assetName = "MenuBarIcon"
  static let sideLength: CGFloat = 18
  static let contentInset: CGFloat = 0
}
```

Replace the `scope` symbol in `MenuBarLabel` with:

```swift
Image(MenuBarIconConfiguration.assetName, bundle: .module)
  .resizable()
  .renderingMode(.original)
  .interpolation(.high)
  .scaledToFit()
  .padding(MenuBarIconConfiguration.contentInset)
  .frame(
    width: MenuBarIconConfiguration.sideLength,
    height: MenuBarIconConfiguration.sideLength
  )
```

Keep the existing alert `Circle`, offsets, and accessibility label unchanged.

- [ ] **Step 5: Package the SwiftPM resource bundle into the local app**

After copying the executable in `script/build_and_run.sh`, add:

```bash
cp -R "$BUILD_DIR/$RESOURCE_BUNDLE_NAME" "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
```

Keep the existing localization copies because localized strings are loaded from the main application bundle.

- [ ] **Step 6: Run the focused test and verify GREEN**

Run the focused command from Step 2.

Expected: `usesAFullBleedColorMenuBarIcon` passes.

- [ ] **Step 7: Run the full build and test suite**

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

- [ ] **Step 8: Build, launch, and inspect the packaged application**

Run:

```bash
./script/build_and_run.sh --verify
test -f dist/CodexRadar.app/CodexRadar_CodexRadar.bundle/MenuBarIcon.png
pgrep -fl CodexRadar
```

Expected: bundle verification succeeds, the PNG exists in the packaged resource bundle, and the application process stays running. Inspect the menu bar in both system appearances and confirm that the blue radar fills its 18-point canvas while the red alert dot remains visible.

- [ ] **Step 9: Commit the implementation**

```bash
git add \
  Sources/CodexRadar/Resources/MenuBarIcon.png \
  Sources/CodexRadar/Views/MenuBarView.swift \
  Tests/CodexRadarTests/MenuActionLayoutTests.swift \
  script/build_and_run.sh
git commit -m "feat: add full-bleed menu bar icon"
```
