# Secure Automatic Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 CodexRadar 建立 Sparkle 2.9.4 自动更新、Universal 2 ad-hoc 发布包、真实 Mac 候选资格测试，以及 GitHub Draft → Immutable Pre-release → Production Feed 的安全发布链路。

**Architecture:** 先把版本、应用组装、嵌套签名、验证和 CI 收敛到仓库脚本，再通过 `UpdaterProviding` 将 Sparkle 隔离在 About UI 之外。发布分成 `prepare-candidate` 与 `publish-update` 两个 workflow；私钥只进入前者的单一 Sparkle 签名步骤，后者重新验证 Draft、公开不可变资产并使用 blob SHA compare-and-swap 激活 signed appcast。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Package Manager、Swift Testing、Sparkle 2.9.4、Bash 3.2、GitHub Actions、GitHub CLI、macOS 14+

## Global Constraints

- 最低系统版本保持 macOS 14；发布应用、Sparkle framework、XPC services、helpers 和其他 Mach-O 必须同时包含 `arm64` 与 `x86_64`。
- Sparkle 必须精确锁定到 `2.9.4`，并提交 `Package.resolved`；升级版本必须重新执行完整更新故障矩阵。
- Bundle ID 固定为 `com.terence.codex-radar`；Production Feed 固定为 `https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml`。
- 正式包必须设置 `SUEnableAutomaticChecks=true`、`SUAutomaticallyUpdate=true`、`SUVerifyUpdateBeforeExtraction=true`、`SURequireSignedFeed=true` 和 `CodexRadarUpdatesEnabled=true`；开发与测试包最后一项必须为 `false`。
- 当前 `SIGNING_MODE=adhoc`，所有 GitHub Release 都标记为 Pre-release，并明确说明未经 Developer ID 签名和 Apple 公证。
- Ed25519 私钥不进入命令参数、工作目录、临时文件、缓存或 Artifact；CI 只通过 stdin 与 `--ed-key-file -` 交给 Sparkle 工具。
- 私钥只暴露给 `prepare-candidate` 的单一签名步骤；该步骤不运行项目脚本、构建命令或第三方 Action。
- 所有 Action 固定完整 commit SHA；build/test job 使用 `contents: read`，只有创建 Draft、公开 Release 或更新 appcast 的 job 使用 `contents: write`。
- 生产 appcast 只保留一个完整 entry、不生成 delta、不使用 channel；最低系统版本提高前必须先设计并实现多 entry 迁移。
- 任何失败版本的 App Version、build number 和 tag 永久作废；同一标识不得重新构建或复用。
- 所有代码、标识符、注释和提交信息使用 English。

## File Map

- Create `version.env`: App Version 和 build number 的唯一来源。
- Create `config/update.env`: Sparkle 版本、公钥、Production Feed 和更新开关的非敏感固定配置。
- Modify `Package.swift` and create `Package.resolved`: 精确引入 Sparkle 2.9.4。
- Create `Sources/CodexRadar/Updates/UpdaterProviding.swift`: updater 协议、状态模型、禁用实现和配置解析。
- Create `Sources/CodexRadar/Updates/SparkleUpdaterController.swift`: Sparkle adapter、诊断与用户主动检查。
- Create `Sources/CodexRadar/Updates/UpdateInstallationLocation.swift`: 只读位置与 App Translocation 预检。
- Modify `Sources/CodexRadar/App/CodexRadarApp.swift`, `SettingsView.swift`, and `AboutView.swift`: 注入进程级 updater 并实现 About 更新 Section。
- Modify both `Localizable.strings`: English、简体中文和可访问性文案。
- Create `script/lib/release_common.sh`: 安全读取配置、版本校验和通用失败函数。
- Create `script/package_app.sh`, `sign_app.sh`, `verify_app.sh`, and `package_release.sh`: Universal 2 组装、显式签名、验证和 ZIP。
- Create `script/prepare_appcast_inputs.sh` and `verify_update_artifacts.sh`: appcast 签名前输入与签名后验证。
- Create `script/qualify_update.sh`: loopback qualification server 与 Sparkle CLI 更新测试。
- Create `script/halt_distribution.sh`: 功能回归时 compare-and-swap 恢复上一份 signed appcast。
- Modify `script/build_and_run.sh`: 复用统一组装与签名。
- Create `.github/workflows/ci.yml`, `prepare-candidate.yml`, and `publish-update.yml`.
- Create `.github/CODEOWNERS`: 保护 workflow、发布脚本、update config 和 appcast。
- Create Swift updater tests and `Tests/ScriptTests/*.sh` 发布链路测试。
- Create `docs/releasing.md`, modify `README.md`, and create initial signed `appcast.xml`.

---

### Task 1: Versioned Packaging Foundation

**Files:**
- Create: `version.env`
- Create: `script/lib/release_common.sh`
- Create: `Tests/ScriptTests/release_common_tests.sh`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Produces: `load_version_config <path>`, `validate_release_tag <tag>`, global version/package constants, and `release_asset_basename`.
- Consumes: Bash 3.2; configuration is parsed as data and never executed with `source`.

- [ ] **Step 1: Add failing configuration tests**

Create `Tests/ScriptTests/release_common_tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
printf 'MARKETING_VERSION=0.2.0\nBUILD_NUMBER=2\n' >"$fixture_dir/valid.env"
load_version_config "$fixture_dir/valid.env"
[[ "$MARKETING_VERSION" == "0.2.0" ]]
[[ "$BUILD_NUMBER" == "2" ]]
validate_release_tag "v0.2.0"

printf 'MARKETING_VERSION=0.2\nBUILD_NUMBER=2\n' >"$fixture_dir/bad-version.env"
if (load_version_config "$fixture_dir/bad-version.env"); then
  echo "invalid marketing version was accepted" >&2
  exit 1
fi
```

- [ ] **Step 2: Verify the red state**

Run `bash Tests/ScriptTests/release_common_tests.sh`.

Expected: failure because `script/lib/release_common.sh` does not exist.

- [ ] **Step 3: Add the canonical version and parser**

Create `version.env`:

```dotenv
MARKETING_VERSION=0.1.0
BUILD_NUMBER=1
```

Create `script/lib/release_common.sh`:

```bash
#!/usr/bin/env bash

APP_NAME="CodexRadar"
BUNDLE_ID="com.terence.codex-radar"
MIN_SYSTEM_VERSION="14.0"
RESOURCE_BUNDLE_NAME="CodexRadar_CodexRadar.bundle"

die() { echo "$*" >&2; return 1; }

load_version_config() {
  local config_path="$1" key value
  MARKETING_VERSION=""
  BUILD_NUMBER=""
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    [[ -z "$key$value" ]] && continue
    case "$key" in
      MARKETING_VERSION)
        [[ -z "$MARKETING_VERSION" ]] || die "duplicate MARKETING_VERSION" || return 1
        MARKETING_VERSION="$value"
        ;;
      BUILD_NUMBER)
        [[ -z "$BUILD_NUMBER" ]] || die "duplicate BUILD_NUMBER" || return 1
        BUILD_NUMBER="$value"
        ;;
      *) die "unknown version key: $key" || return 1 ;;
    esac
  done <"$config_path"
  [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid MARKETING_VERSION" || return 1
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "invalid BUILD_NUMBER" || return 1
}

validate_release_tag() {
  [[ "$1" == "v$MARKETING_VERSION" ]] || die "tag must equal v$MARKETING_VERSION"
}

release_asset_basename() {
  printf '%s-v%s-macos-universal' "$APP_NAME" "$MARKETING_VERSION"
}
```

- [ ] **Step 4: Load `version.env` from the existing launcher**

Remove only the hard-coded marketing/build values from `build_and_run.sh`, source the function library, and call `load_version_config "$ROOT_DIR/version.env"`. Task 6 will replace duplicated assembly after the shared packager and signer exist.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash Tests/ScriptTests/release_common_tests.sh
bash -n script/lib/release_common.sh script/build_and_run.sh
swift test
```

Expected: all commands exit successfully.

```bash
git add version.env script/lib/release_common.sh script/build_and_run.sh Tests/ScriptTests/release_common_tests.sh
git commit -m "build: add canonical release version config"
```

---

### Task 2: Sparkle Dependency and Updater Domain Model

**Files:**
- Modify: `Package.swift`
- Create: `Package.resolved`
- Create: `Sources/CodexRadar/Updates/UpdaterProviding.swift`
- Create: `Tests/CodexRadarTests/UpdaterSettingsModelTests.swift`

**Interfaces:**
- Produces: `UpdaterProviding`, `UpdaterSettingsModel`, `DisabledUpdaterController`, `UpdateConfiguration`, and `UpdaterFactory.make(bundle:)`.
- Consumes: Sparkle product `2.9.4`; About UI never imports Sparkle.

- [ ] **Step 1: Write failing updater state tests**

Use a fake implementing this exact contract:

```swift
@MainActor
protocol UpdaterProviding: AnyObject {
  var isAvailable: Bool { get }
  var unavailableReasonKey: String? { get }
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var canCheckForUpdates: Bool { get }
  func checkForUpdates()
}
```

Verify initialization, one-toggle synchronization of both automatic properties, exactly one user-driven call, refreshed `canCheckForUpdates`, and disabled behavior without feed access.
Create a second model over the same persisted fake provider and verify the disabled automatic-update choice remains disabled after reconstruction.

- [ ] **Step 2: Verify the red state**

Run `swift test --filter UpdaterSettingsModelTests`.

Expected: compilation fails because updater types do not exist.

- [ ] **Step 3: Pin Sparkle and implement the model**

Add to `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
],
```

Add `.product(name: "Sparkle", package: "Sparkle")` to the executable target. Implement:

```swift
@MainActor
final class UpdaterSettingsModel: ObservableObject {
  @Published private(set) var isAvailable: Bool
  @Published private(set) var unavailableReasonKey: String?
  @Published private(set) var automaticUpdatesEnabled: Bool
  @Published private(set) var canCheckForUpdates: Bool
  private let provider: any UpdaterProviding

  init(provider: any UpdaterProviding) {
    self.provider = provider
    isAvailable = provider.isAvailable
    unavailableReasonKey = provider.unavailableReasonKey
    automaticUpdatesEnabled = provider.automaticallyChecksForUpdates
      && provider.automaticallyDownloadsUpdates
    canCheckForUpdates = provider.canCheckForUpdates
  }

  func setAutomaticUpdatesEnabled(_ enabled: Bool) {
    provider.automaticallyChecksForUpdates = enabled
    provider.automaticallyDownloadsUpdates = enabled
    refresh()
  }

  func checkForUpdates() {
    guard provider.isAvailable, provider.canCheckForUpdates else { return }
    provider.checkForUpdates()
    refresh()
  }

  func refresh() {
    isAvailable = provider.isAvailable
    unavailableReasonKey = provider.unavailableReasonKey
    automaticUpdatesEnabled = provider.automaticallyChecksForUpdates
      && provider.automaticallyDownloadsUpdates
    canCheckForUpdates = provider.canCheckForUpdates
  }
}
```

`UpdateConfiguration` parses `CodexRadarUpdatesEnabled` as a strict Boolean. `UpdaterFactory` returns `DisabledUpdaterController` for `swift run`, tests and development packages.

- [ ] **Step 4: Resolve, verify, and commit**

Run:

```bash
swift package resolve
swift test --filter UpdaterSettingsModelTests
swift test
```

Expected: Sparkle resolves exactly to `2.9.4`; tests pass.

```bash
git add Package.swift Package.resolved Sources/CodexRadar/Updates/UpdaterProviding.swift Tests/CodexRadarTests/UpdaterSettingsModelTests.swift
git commit -m "feat: add updater domain model"
```

---

### Task 3: Sparkle Adapter and Installation Preflight

**Files:**
- Create: `Sources/CodexRadar/Updates/SparkleUpdaterController.swift`
- Create: `Sources/CodexRadar/Updates/UpdateInstallationLocation.swift`
- Create: `Tests/CodexRadarTests/UpdateInstallationLocationTests.swift`

**Interfaces:**
- Produces: `SparkleUpdaterController` and `UpdateInstallationLocation.evaluate(bundleURL:homeURL:isWritable:)`.
- Consumes: `SPUStandardUpdaterController`, `SPUUpdaterDelegate`, and Task 2 protocol.

- [ ] **Step 1: Write failing location tests**

Cover:

```swift
#expect(evaluate("/Applications/CodexRadar.app", writable: true) == .supported)
#expect(evaluate("/Users/test/Applications/CodexRadar.app", writable: true) == .supported)
#expect(evaluate("/Volumes/ReadOnly/CodexRadar.app", writable: false) == .readOnly)
#expect(evaluate("/private/var/folders/a/AppTranslocation/x/CodexRadar.app", writable: true) == .translocated)
#expect(evaluate("/Users/test/Downloads/CodexRadar.app", writable: true) == .unsupportedLocation)
```

Inject home URL and writability; never depend on the developer machine.

- [ ] **Step 2: Verify the red state**

Run `swift test --filter UpdateInstallationLocationTests`; expect missing-type failure.

- [ ] **Step 3: Implement preflight and adapter**

The adapter must initialize `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)`, expose Sparkle automatic settings and `canCheckForUpdates`, preflight only user-driven checks, and show one `NSAlert` telling the user to quit and move CodexRadar to `/Applications` or `~/Applications`. Implement `updater(_:didAbortWithError:)` and log only error domain/code via `Logger(subsystem: "com.terence.codex-radar", category: "updates")`.
Background failures only log and never create a CodexRadar alert; user-driven checks remain on Sparkle's standard user-driver path so no-update and updater errors remain visible.

- [ ] **Step 4: Verify and commit**

Run focused and full Swift suites; expect success.

```bash
git add Sources/CodexRadar/Updates/SparkleUpdaterController.swift Sources/CodexRadar/Updates/UpdateInstallationLocation.swift Tests/CodexRadarTests/UpdateInstallationLocationTests.swift
git commit -m "feat: add Sparkle updater adapter"
```

---

### Task 4: About Update UI and Application Lifetime

**Files:**
- Modify: `Sources/CodexRadar/App/CodexRadarApp.swift`
- Modify: `Sources/CodexRadar/Views/SettingsView.swift`
- Modify: `Sources/CodexRadar/Views/AboutView.swift`
- Modify: both localization files
- Modify: `Tests/CodexRadarTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: one process-lifetime `UpdaterSettingsModel` owned by `AppDelegate`.
- Produces: toggle, version/check row, disabled reason and localized accessibility labels.

- [ ] **Step 1: Add failing localization tests**

Assert English and Simplified Chinese for `Updates`, `Automatically check for updates`, `Check for Updates…`, release-only unavailability, and the move-to-Applications instruction.

- [ ] **Step 2: Wire the process-lifetime updater**

Add to `AppDelegate`:

```swift
@MainActor
let updaterSettings = UpdaterSettingsModel(provider: UpdaterFactory.make(bundle: .main))
```

Pass it through `SettingsView` to `AboutView`. Never instantiate an updater from a SwiftUI `body` or view initializer.

- [ ] **Step 3: Add the About update Section**

Between hero and links, render a toggle backed by `setAutomaticUpdatesEnabled(_:)`, the current App Version with a trailing user-driven button, a disabled button when `canCheckForUpdates` is false, or the reason instead of controls when updater is unavailable. Call `refresh()` on appear; add VoiceOver labels; do not add channel UI.

- [ ] **Step 4: Verify and commit**

Run localization, updater and full Swift tests; expect success.

```bash
git add Sources/CodexRadar/App/CodexRadarApp.swift Sources/CodexRadar/Views/SettingsView.swift Sources/CodexRadar/Views/AboutView.swift Sources/CodexRadar/Resources Tests/CodexRadarTests/AppLocalizationTests.swift
git commit -m "feat: add About update controls"
```

---

### Task 5: Universal 2 App Assembly with Sparkle

**Files:**
- Create: `config/update.env`
- Create: `script/package_app.sh`
- Create: `Tests/ScriptTests/package_verification_tests.sh`

**Interfaces:**
- Produces: `package_app.sh --output PATH --configuration debug|release --architectures ARCH_LIST --updates-enabled true|false`.
- Consumes: Tasks 1–4, SwiftPM products, public update configuration, `ditto`, `lipo`, `otool`, and `plutil`.

- [ ] **Step 1: Add failing package fixtures**

The shell suite must reject duplicate/unknown architectures, missing public key when updates are enabled, a non-2.9.4 Sparkle version, and different resource sets between architecture scratch paths.

- [ ] **Step 2: Verify the red state**

Run `bash Tests/ScriptTests/package_verification_tests.sh`.

Expected: failure because `package_app.sh` does not exist.

- [ ] **Step 3: Commit actual public update configuration**

Download Sparkle 2.9.4 tools, verify archive SHA-256 `ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9`, generate the application-specific key in the operator keychain, and create `config/update.env` from the real public output:

```bash
./bin/generate_keys --account com.terence.codex-radar
public_key="$(./bin/generate_keys --account com.terence.codex-radar -p)"
decoded_size="$(printf '%s' "$public_key" | /usr/bin/base64 -D | wc -c | tr -d ' ')"
[[ "$decoded_size" == "32" ]]
apply_patch <<PATCH
*** Begin Patch
*** Add File: config/update.env
+SPARKLE_VERSION=2.9.4
+SPARKLE_PUBLIC_ED_KEY=$public_key
+PRODUCTION_FEED_URL=https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml
*** End Patch
PATCH
```

Keep the private key in the operator keychain until Task 10 transfers it to the Environment secret and creates the encrypted offline backup.

- [ ] **Step 4: Implement `package_app.sh`**

The script must parse arguments without `eval`, load both config files as data, build each architecture in a distinct `--scratch-path`, compare normalized resource lists, merge the main executable with `lipo -create`, copy resources with `ditto`, and locate exactly one SwiftPM `Sparkle.framework`. Copy it to `Contents/Frameworks` preserving symlinks, reject escaped paths, and assert `@executable_path/../Frameworks` exists in `LC_RPATH`.

Generate final Info.plist from config. Release-update mode writes the exact feed/public key and five Boolean update settings; development mode writes `CodexRadarUpdatesEnabled=false` and does not create a live updater.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash Tests/ScriptTests/package_verification_tests.sh
./script/package_app.sh --output dist --configuration debug --architectures "$(uname -m)" --updates-enabled false
plutil -extract CodexRadarUpdatesEnabled raw dist/CodexRadar.app/Contents/Info.plist
swift test
```

Expected: fixtures pass; extracted value is `false`; Swift tests pass.

```bash
git add config/update.env script/package_app.sh Tests/ScriptTests/package_verification_tests.sh
git commit -m "build: package app with Sparkle framework"
```

---

### Task 6: Nested Signing, Final Verification, and Release Archive

**Files:**
- Create: `script/sign_app.sh`
- Create: `script/verify_app.sh`
- Create: `script/package_release.sh`
- Modify: `Tests/ScriptTests/package_verification_tests.sh`
- Modify: `script/build_and_run.sh`

**Interfaces:**
- Produces: signed `.app`, versioned Universal ZIP, `.sha256`, and `.manifest`.
- Consumes: `package_app.sh`, explicit `SIGNING_MODE=adhoc`, and fixed Sparkle 2.9.4 layout.

- [ ] **Step 1: Extend failure fixtures**

Add an escaped symlink, an extra ZIP top-level file, a missing XPC service, a non-Mach-O executable, a single-architecture nested binary, and a mismatched Info.plist version. Each fixture must fail without deleting the fixture root.

- [ ] **Step 2: Implement explicit inside-out signing**

Resolve and validate unique targets, then sign in this exact order:

```text
Sparkle.framework/Versions/B/XPCServices/*.xpc nested executables
Sparkle.framework/Versions/B/Autoupdate
Sparkle.framework/Versions/B/Updater.app
Sparkle.framework
CodexRadar main executable
CodexRadar.app
```

Use `codesign --force --sign -` for ad-hoc mode. Never use `codesign --deep` to perform signing. A future `developer-id` mode must fail unless every certificate/notarization input exists; never fall back to ad-hoc.

- [ ] **Step 3: Implement final verifier**

`verify_app.sh` parses the final Info.plist, checks exact version/build/bundle/minimum OS/update configuration, recursively enumerates Mach-O with `file`, checks expected architectures with `lipo -archs`, validates all symlinks remain inside the bundle, and runs `codesign --verify --deep --strict --verbose=2` only as verification.

- [ ] **Step 4: Implement archive orchestration**

Use an explicit `mktemp -d` work directory with a trap, package/sign/verify Universal 2, create ZIP with `ditto -c -k --keepParent`, reject AppleDouble and any top-level entry other than `CodexRadar.app`, extract to a second directory, rerun verifier, then write SHA-256 and a manifest containing version, build, byte length, archive SHA-256 and archive name.

- [ ] **Step 5: Reuse the packager and signer from `build_and_run.sh`**

Call `package_app.sh` for `$(uname -m)` and `sign_app.sh --signing-mode adhoc`. Preserve `run`, `debug`, `logs`, `telemetry`, and `verify`; remove the old inline Info.plist assembly and `codesign --deep` signing command.

- [ ] **Step 6: Verify and commit**

Run:

```bash
bash Tests/ScriptTests/package_verification_tests.sh
./script/package_release.sh --output dist/release --signing-mode adhoc
shasum -a 256 --check dist/release/*.sha256
```

Expected: fixtures, archive and extracted app pass all checks.

```bash
git add script/sign_app.sh script/verify_app.sh script/package_release.sh script/build_and_run.sh Tests/ScriptTests/package_verification_tests.sh
git commit -m "build: sign and verify release archives"
```

---

### Task 7: Appcast Inputs and Signed Artifact Verification

**Files:**
- Create: `script/prepare_appcast_inputs.sh`
- Create: `script/verify_update_artifacts.sh`
- Create: `Tests/ScriptTests/update_feed_tests.sh`

**Interfaces:**
- Produces: isolated production/qualification input directories and post-signing validation.
- Consumes: exact ZIP/manifest, final Info.plist, current Production Feed, and Sparkle verification tools.

- [ ] **Step 1: Add failing feed tests**

Fixtures cover mismatched `sparkle:version`, non-increasing build, `latest/download` URL, wrong archive length, missing Ed25519 signature, changed signed feed byte, absolute qualification enclosure, minimum OS increase under single-entry policy, and CAS conflict states.
Also cover the one-time bootstrap state where no `appcast.xml` exists; every non-bootstrap run must reject a missing Production Feed.

- [ ] **Step 2: Implement pre-signing inputs**

Create two independent directories with the exact same ZIP. Production uses:

```text
release_url="https://github.com/tangwz/codex-radar/releases/download/v${MARKETING_VERSION}/${ARCHIVE_NAME}"
```

Qualification uses `ARCHIVE_NAME` as a relative enclosure. First implementation has no external release-notes file. Read the current Production Feed only to assert build monotonicity and minimum OS compatibility.
Accept a `--bootstrap` flag only when the Production Feed is absent and GitHub Release history is empty. The intended first attempt is App Version `0.1.0`, build `1`, but if that tag is burned before feed activation, a higher version and build under a new tag remains eligible. Before signing, compare the candidate identity with `version.env` at every other protected `v*` tag and require both values to be strictly greater; all candidates after the first feed exists require that signed feed.

- [ ] **Step 3: Implement post-signing validation**

Use `plutil`, `xmllint`, `shasum`, and Sparkle verification to check signed feed, archive signature, exact bytes/length/version/build, one entry, fixed production URL, relative qualification URL, and matching public key in the extracted final app.

- [ ] **Step 4: Verify and commit**

Run:

```bash
bash Tests/ScriptTests/update_feed_tests.sh
bash -n script/prepare_appcast_inputs.sh script/verify_update_artifacts.sh
```

Expected: all fixtures pass.

```bash
git add script/prepare_appcast_inputs.sh script/verify_update_artifacts.sh Tests/ScriptTests/update_feed_tests.sh
git commit -m "build: validate signed update artifacts"
```

---

### Task 8: Local Qualification Bundle

**Files:**
- Create: `script/qualify_update.sh`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`

**Interfaces:**
- Produces: one operator command that drives an exact prior Production Update through Sparkle CLI.
- Consumes: manifest, exact Draft ZIP, signed relative appcast, Sparkle 2.9.4 `bin/sparkle`, and previous `.app`.

- [ ] **Step 1: Add failing qualification tests**

Inject Python path, Sparkle CLI and a fake runner. Assert loopback-only binding, random port, manifest failure before server start, CLI version rejection, cleanup on success/failure/interrupt, and this argument set:

```text
SPARKLE_CLI PREVIOUS_APP --application PREVIOUS_APP --check-immediately --feed-url http://127.0.0.1:PORT/appcast.xml --interactive --verbose
```

- [ ] **Step 2: Implement qualification**

Support:

```bash
./script/qualify_update.sh --bundle /path/to/qualification --previous-app /Applications/CodexRadar.app
```

Copy the previous app into a controlled writable directory, validate it is the immediately previous Production Update, serve only the qualification directory on `127.0.0.1`, run Sparkle CLI, verify installed version/build/settings, and stop the server in EXIT/INT/TERM traps. Never alter the original application.

- [ ] **Step 3: Verify and commit**

Run script fixtures and `bash -n script/qualify_update.sh`; expect success.

```bash
git add script/qualify_update.sh Tests/ScriptTests/update_feed_tests.sh
git commit -m "build: add local update qualification"
```

---

### Task 9: Continuous Integration and Ownership

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/CODEOWNERS`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`

**Interfaces:**
- Produces: PR/main Swift, shell, packaging and workflow checks with read-only permissions.
- Consumes: Tasks 1–8; no publishing secret.

- [ ] **Step 1: Add workflow static assertions**

Reject global `contents: write`, unpinned `uses:`, secret references outside `sign-candidate`, missing concurrency, and missing script syntax checks.

- [ ] **Step 2: Create CI**

Use `actions/checkout` pinned to `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0`. Set `permissions: contents: read`, cancellable branch concurrency, and run:

```bash
swift test
bash Tests/ScriptTests/release_common_tests.sh
bash Tests/ScriptTests/package_verification_tests.sh
bash Tests/ScriptTests/update_feed_tests.sh
find script -name '*.sh' -print0 | xargs -0 -n1 bash -n
./script/package_app.sh --output dist/ci --configuration release --architectures "$(uname -m)" --updates-enabled false
```

Install actionlint `1.7.12` from its fixed Release URL and verify before extraction. Select the digest by runner architecture:

```text
darwin_arm64  aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
darwin_amd64  5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
```

Do not download an unverified latest binary.

- [ ] **Step 3: Add ownership**

Create:

```text
/.github/workflows/ @tangwz
/script/ @tangwz
/config/update.env @tangwz
/appcast.xml @tangwz
```

- [ ] **Step 4: Verify and commit**

Run workflow fixture tests and `actionlint .github/workflows/ci.yml`; expect success.

```bash
git add .github/workflows/ci.yml .github/CODEOWNERS Tests/ScriptTests/update_feed_tests.sh
git commit -m "ci: validate update packaging"
```

---

### Task 10: Ed25519 Bootstrap and Candidate Preparation

**Files:**
- Create: `.github/workflows/prepare-candidate.yml`
- Create: `docs/releasing.md`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`
- Modify: `config/update.env`

**Interfaces:**
- Produces: Draft Candidate Release and seven-day qualification Artifact.
- Consumes: `release` Environment secret `SPARKLE_ED_PRIVATE_KEY`, committed public key, tag on `main`, and Sparkle tools archive SHA-256 `ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9`.

- [ ] **Step 1: Transfer and back up the existing key once**

On the controlled operator Mac, first verify the keychain public key still equals `config/update.env`:

```bash
./bin/generate_keys --account com.terence.codex-radar -p
```

Export the private key only for transfer using a user-only-readable file, feed it to `gh secret set SPARKLE_ED_PRIVATE_KEY --env release` through stdin, create the encrypted offline backup, and remove the transfer file with a trap. Document that abnormal-termination cleanup is best-effort.

- [ ] **Step 2: Add failing candidate workflow assertions**

Require a `v*` tag path, a no-secret manual dry run, tag/version/build/ancestry checks, read-only build job, one `release` Environment signing job, exactly one secret reference, pinned actions, Draft-only completion, and qualification Artifact retention of seven days.

- [ ] **Step 3: Implement `prepare-candidate.yml`**

The workflow must:

1. verify tag and `origin/main` ancestry;
2. run all tests and Universal 2 packaging;
3. upload the archive Artifact using `actions/upload-artifact` pinned to `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`;
4. enter `release` Environment only in `sign-candidate`;
5. download and checksum Sparkle 2.9.4 tools before secret exposure;
6. prepare both appcast input directories before secret exposure;
7. in one step, disable tracing and run only Sparkle `generate_appcast --maximum-versions 1 --ed-key-file -` for production and qualification;
8. after that step, run repository validators, create Draft with `gh`, upload ZIP/checksum/manifest/candidate appcast, redownload authenticated Draft assets and compare exact bytes;
9. upload the redownloaded ZIP, qualification appcast, manifest and fixed Sparkle CLI as a seven-day Artifact;
10. finish while Release remains Draft.

Every checkout uses `actions/checkout` pinned to `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0`; every Artifact download uses `actions/download-artifact` pinned to `3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c`.

The same repository/tag concurrency group is later used by `publish-update`. A failed candidate keeps its burned tag permanently; the operator deletes only an existing Draft Release, then retries with a higher version, build number, and matching new tag.

- [ ] **Step 4: Verify and commit**

Run workflow tests and `actionlint`; expect no unpinned Action, permission leak or secret-scope failure.

```bash
git add .github/workflows/prepare-candidate.yml docs/releasing.md Tests/ScriptTests/update_feed_tests.sh config/update.env
git commit -m "ci: prepare signed update candidates"
```

---

### Task 11: Publish, Public Reverification, and Feed Activation

**Files:**
- Create: `.github/workflows/publish-update.yml`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`
- Modify: `docs/releasing.md`

**Interfaces:**
- Produces: Immutable Pre-release, public verification, Production Feed activation, and resumable Activation Pending handling.
- Consumes: manual `tag`, Draft assets, current `appcast.xml` blob SHA, and no private key.

- [ ] **Step 1: Add failing publish assertions**

Require `workflow_dispatch`, one tag input, no secret reference, independent Draft download, Draft-state check, shared concurrency, verification before publish, and current blob SHA for Contents API writes.

- [ ] **Step 2: Implement publish workflow**

The workflow must:

1. validate tag/version/commit;
2. confirm Draft state and download ZIP/checksum/manifest/candidate appcast;
3. independently rerun archive/appcast verification;
4. publish using `gh release edit "$TAG" --draft=false --prerelease`;
5. redownload fixed public URLs and verify length, SHA-256, Ed25519 and release integrity;
6. on public-verification failure, delete only the Release, retain the burned tag and leave Production Feed unchanged;
7. fetch current Production Feed bytes and blob SHA;
8. if current bytes equal candidate, resume Activation Pending without writing;
9. if current bytes equal the expected previous signed feed, PUT candidate base64 with current blob SHA and `branch=main`;
10. reject a third state, HTTP 409 and HTTP 422;
11. poll raw URL with bounded backoff until exact candidate bytes appear;
12. on timeout report Activation Pending without rollback; on unknown raw bytes require investigation.

For the one-time bootstrap state only, a 404 Production Feed may be created without a blob SHA after public-asset verification and a second check that release history, excluding the current Candidate, and the feed are still empty. Fetch protected tags and revalidate version/build monotonicity immediately before this bootstrap CAS so a tag created after signing cannot be missed. Bootstrap eligibility is state-based so a burned initial tag can be replaced only by a higher version and build under a new tag. GitHub conflict response terminates the run; every subsequent write requires the current blob SHA.

After CAS succeeds, never delete or roll back the valid public Release.

- [ ] **Step 3: Verify and commit**

Run workflow tests and `actionlint`; expect success.

```bash
git add .github/workflows/publish-update.yml Tests/ScriptTests/update_feed_tests.sh docs/releasing.md
git commit -m "ci: publish and activate signed updates"
```

---

### Task 12: Distribution Halt, Bootstrap Feed, and Acceptance

**Files:**
- Create: `script/halt_distribution.sh`
- Create: `appcast.xml`
- Modify: `README.md`
- Modify: `docs/releasing.md`
- Modify: `Tests/ScriptTests/update_feed_tests.sh`

**Interfaces:**
- Produces: Distribution Halt, first signed Production Feed, bootstrap documentation and real-Mac acceptance record.
- Consumes: previous signed appcast from Git history, current blob SHA, immutable Release, and authenticated operator `gh` session.

- [ ] **Step 1: Implement Distribution Halt**

Require `--previous-commit`, fetch current content/blob SHA and previous appcast via GitHub APIs, verify both signed feeds, confirm previous build is lower, show both SHA-256 values, require the operator to type the current tag exactly, then CAS the exact previous bytes. Never delete Release/tag or claim installed clients were downgraded. Poll raw URL before success.

- [ ] **Step 2: Test Distribution Halt and Activation Pending**

Use fake `gh`/HTTP fixtures for blob conflict, invalid previous signature, current/candidate/unknown raw bytes, timeout, and successful exact-byte restore. All fixtures must be read-only outside their temporary directories.

- [ ] **Step 3: Create bootstrap Production Feed**

Use the candidate workflow for the first Sparkle-enabled manual bootstrap Release. With no prior Sparkle Production Update, qualify a lower-build production-equivalent copy and run the complete real-Mac matrix. Activate a signed single-entry `appcast.xml` pointing at the immutable bootstrap Release; the same build must report no update.

- [ ] **Step 4: Update first-install documentation**

README provides fixed Release URL, SHA-256 verification, explicit “not Developer ID signed or notarized” notice, and only macOS per-application Open/System Settings instructions. Exclude `spctl --master-disable`, global Gatekeeper changes, and any claim that same-page SHA-256 authenticates developer identity.

- [ ] **Step 5: Run automated acceptance**

Run:

```bash
swift test
bash Tests/ScriptTests/release_common_tests.sh
bash Tests/ScriptTests/package_verification_tests.sh
bash Tests/ScriptTests/update_feed_tests.sh
find script -name '*.sh' -print0 | xargs -0 -n1 bash -n
actionlint .github/workflows/*.yml
./script/package_release.sh --output dist/release --signing-mode adhoc
```

Expected: suites/static checks pass; ZIP is Universal 2, signed, structurally valid and update-enabled.

- [ ] **Step 6: Run real-Mac acceptance**

Cover bootstrap manual install, exact previous → candidate happy path, first-bootstrap fault matrix, settings preservation, About manual check, invisible Draft, fixed public URL verification, Activation Pending resume, and Distribution Halt on a disposable feed fixture.

- [ ] **Step 7: Commit final operations**

```bash
git add script/halt_distribution.sh appcast.xml README.md docs/releasing.md Tests/ScriptTests/update_feed_tests.sh
git commit -m "docs: finalize secure update operations"
```

---

## Repository Configuration Checklist

- [ ] Enable GitHub Immutable Releases before publishing bootstrap.
- [ ] Create `release` Environment, restrict it to `v*`, and store only `SPARKLE_ED_PRIVATE_KEY` there.
- [ ] Keep Single-Operator self-approval until a second trusted operator exists; then require reviewer and disable self-review.
- [ ] Protect `main`, require CI, apply CODEOWNERS, and grant only the release actor minimal appcast-CAS bypass.
- [ ] Preserve owner/repository/default-branch/path for the Production Feed compatibility contract.
- [ ] Store one encrypted offline private-key backup and its recovery-test date outside the repository.

## Final Verification Matrix

- [ ] Final Info.plist matches version/build/bundle/minimum OS/public key/feed and update flags.
- [ ] Every required Mach-O contains exactly `arm64` and `x86_64`.
- [ ] ZIP has one top-level app, preserves permissions/symlinks and passes extraction revalidation.
- [ ] Production and qualification appcasts are signed, byte-stable and reference the same exact ZIP.
- [ ] Production enclosure is fixed-tag HTTPS; qualification enclosure is relative and loopback-only.
- [ ] No workflow exposes the private key outside one Sparkle signing step.
- [ ] Public Release is immutable before Production Feed CAS.
- [ ] Raw feed returns candidate exact bytes before completion is announced.
- [ ] Functional regression uses Distribution Halt; key incident terminates Update Trust Chain and requires manual bootstrap.
