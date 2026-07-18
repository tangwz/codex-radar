# GitHub Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 CodexRadar 建立可本地复现的 Universal 2 打包链、精简 CI，以及由 `v*` tag 触发的 ad-hoc 签名 GitHub Pre-release 流水线。

**Architecture:** 仓库脚本负责版本校验、应用组装、签名、公证边界、验证和归档；GitHub Actions 仅负责编排、权限和 Release 生命周期。当前签名模式固定为 `adhoc`，未来通过显式切换到 `developer-id` 启用临时 keychain、Developer ID 签名和 Apple 公证，不根据 secrets 是否存在自动降级。

**Tech Stack:** Swift 6.0、Swift Package Manager、macOS 14+、Bash 3.2 compatible shell、GitHub Actions、GitHub CLI、Apple `codesign`/`lipo`/`ditto`/`notarytool`。

## Global Constraints

- 应用名称固定为 `CodexRadar`，bundle identifier 固定为 `com.terence.codex-radar`。
- 最低系统版本固定为 macOS `14.0`。
- 发布产物必须是同时且仅包含 `arm64`、`x86_64` 的 Universal 2 应用。
- `version.env` 是 `MARKETING_VERSION` 与 `BUILD_NUMBER` 的唯一配置来源；首个值为 `0.1.0 (1)`。
- 发布 tag 必须是严格的 `vMAJOR.MINOR.PATCH`，并与 `v${MARKETING_VERSION}` 完全一致。
- 当前 `SIGNING_MODE=adhoc` 只能创建 GitHub Pre-release；不得根据 secrets 自动切换模式。
- tag 对应提交必须属于 `main`，已公开 Release 不得覆盖；失败上传只允许留下 Draft。
- 第三方 GitHub Actions 必须固定到完整 commit SHA。
- 不引入 Sparkle、Homebrew、Linux CLI、dSYM 发布或自动版本提交。
- 所有代码、注释、标识符、提交信息和代码块内容使用 English。

---

## File Structure

- `version.env`：唯一版本配置。
- `script/lib/release_common.sh`：版本解析、tag 校验、main 祖先校验、发布渠道约束和资产命名。
- `script/validate_release.sh`：供本地与 workflow 调用的发布元数据入口。
- `script/package_app.sh`：按调用者声明的架构编译并组装未签名 `.app`。
- `script/sign_app.sh`：显式执行 ad-hoc 或 Developer ID 签名。
- `script/verify_app.sh`：验证 plist、资源、架构、签名及公证状态。
- `script/package_release.sh`：生成 Universal 2 ZIP 和 SHA-256，包含未来公证路径。
- `script/publish_release.sh`：管理 Draft、资产上传和 Pre-release 发布状态。
- `script/tests/*.sh`：不访问 GitHub 的 shell 单元与集成测试。
- `.github/release-notes-adhoc.md`：未公证版本的固定安全提示。
- `.github/workflows/ci.yml`：PR 和 `main` 的精简 macOS CI。
- `.github/workflows/release.yml`：tag 发布与手动 dry run。
- `script/build_and_run.sh`：复用新的组装、签名和验证脚本，保留现有开发入口。
- `README.md`：记录版本准备、dry run 和 tag 发布流程。

### Task 1: Release Metadata and Guard Rails

**Files:**
- Create: `version.env`
- Create: `script/lib/release_common.sh`
- Create: `script/validate_release.sh`
- Create: `script/tests/release_common_test.sh`

**Interfaces:**
- Consumes: repository root and optional tag/commit/main-ref command arguments.
- Produces: `load_version FILE`, `validate_release_tag TAG`, `assert_commit_on_main REPOSITORY COMMIT MAIN_REF`, `validate_release_channel MODE PRERELEASE`, `require_developer_id_environment`, `release_asset_name`, and `release_checksum_name`.

- [ ] **Step 1: Write the failing metadata and guard test**

Create the test directory with `mkdir -p script/tests`, then create `script/tests/release_common_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-release-common.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

expect_failure() {
  local name="$1"
  shift
  if ("$@"); then
    echo "Expected failure: $name" >&2
    exit 1
  fi
}

write_version() {
  local path="$1"
  local version="$2"
  local build="$3"
  {
    printf 'MARKETING_VERSION=%s\n' "$version"
    printf 'BUILD_NUMBER=%s\n' "$build"
  } > "$path"
}

GOOD_VERSION_FILE="$TEST_DIR/version.env"
write_version "$GOOD_VERSION_FILE" "0.1.0" "1"
load_version "$GOOD_VERSION_FILE"
[[ "$MARKETING_VERSION" == "0.1.0" ]]
[[ "$BUILD_NUMBER" == "1" ]]
validate_release_tag "v0.1.0"
[[ "$(release_asset_name)" == "CodexRadar-v0.1.0-macos-universal.zip" ]]
[[ "$(release_checksum_name)" == "CodexRadar-v0.1.0-macos-universal.zip.sha256" ]]

BAD_VERSION_FILE="$TEST_DIR/bad-version.env"
write_version "$BAD_VERSION_FILE" "0.1" "1"
expect_failure "invalid semantic version" load_version "$BAD_VERSION_FILE"

BAD_BUILD_FILE="$TEST_DIR/bad-build.env"
write_version "$BAD_BUILD_FILE" "0.1.0" "0"
expect_failure "non-positive build number" load_version "$BAD_BUILD_FILE"

EXTRA_KEY_FILE="$TEST_DIR/extra-key.env"
{
  printf 'MARKETING_VERSION=0.1.0\n'
  printf 'BUILD_NUMBER=1\n'
  printf 'UNEXPECTED=value\n'
} > "$EXTRA_KEY_FILE"
expect_failure "unexpected version key" load_version "$EXTRA_KEY_FILE"

load_version "$GOOD_VERSION_FILE"
expect_failure "tag mismatch" validate_release_tag "v0.1.1"
expect_failure "tag prefix missing" validate_release_tag "0.1.0"
expect_failure "incomplete semantic version" validate_release_tag "v0.1"
validate_release_channel "adhoc" "true"
expect_failure "adhoc stable release" validate_release_channel "adhoc" "false"
expect_failure "unknown signing mode" validate_release_channel "automatic" "true"

missing_developer_credential() {
  local missing="$1"
  export MACOS_SIGNING_IDENTITY="identity"
  export APP_STORE_CONNECT_API_KEY_P8="key"
  export APP_STORE_CONNECT_KEY_ID="key-id"
  export APP_STORE_CONNECT_ISSUER_ID="issuer-id"
  unset "$missing"
  require_developer_id_environment
}
for missing in \
  MACOS_SIGNING_IDENTITY \
  APP_STORE_CONNECT_API_KEY_P8 \
  APP_STORE_CONNECT_KEY_ID \
  APP_STORE_CONNECT_ISSUER_ID; do
  expect_failure \
    "missing $missing" \
    missing_developer_credential \
    "$missing"
done

REPO_DIR="$TEST_DIR/repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.name "Release Test"
git -C "$REPO_DIR" config user.email "release-test@example.com"
printf 'main\n' > "$REPO_DIR/state.txt"
git -C "$REPO_DIR" add state.txt
git -C "$REPO_DIR" commit -q -m "main"
MAIN_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$MAIN_COMMIT"
assert_commit_on_main "$REPO_DIR" "$MAIN_COMMIT" "refs/remotes/origin/main"

git -C "$REPO_DIR" checkout -q -b release-test
printf 'branch\n' > "$REPO_DIR/state.txt"
git -C "$REPO_DIR" commit -q -am "branch"
BRANCH_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
expect_failure \
  "commit outside main" \
  assert_commit_on_main "$REPO_DIR" "$BRANCH_COMMIT" "refs/remotes/origin/main"

echo "release_common_test: PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
chmod +x script/tests/release_common_test.sh
./script/tests/release_common_test.sh
```

Expected: FAIL because `script/lib/release_common.sh` does not exist.

- [ ] **Step 3: Add strict metadata parsing and release guards**

Create `version.env`:

```bash
MARKETING_VERSION=0.1.0
BUILD_NUMBER=1
```

Create the library directory with `mkdir -p script/lib`, then create `script/lib/release_common.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

CODEX_RADAR_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="CodexRadar"
BUNDLE_ID="com.terence.codex-radar"
MIN_SYSTEM_VERSION="14.0"
RESOURCE_BUNDLE_NAME="CodexRadar_CodexRadar.bundle"

codex_radar_die() {
  echo "ERROR: $*" >&2
  return 1
}

load_version() {
  local version_file="${1:-$CODEX_RADAR_ROOT_DIR/version.env}"
  local key=""
  local value=""
  local extra=""

  MARKETING_VERSION=""
  BUILD_NUMBER=""
  [[ -f "$version_file" ]] \
    || {
      codex_radar_die "Missing version file: $version_file"
      return 1
    }

  while IFS='=' read -r key value extra || [[ -n "$key" ]]; do
    [[ -z "$key" ]] && continue
    [[ -z "$extra" ]] \
      || {
        codex_radar_die "Invalid version line for key: $key"
        return 1
      }
    case "$key" in
      MARKETING_VERSION)
        [[ -z "$MARKETING_VERSION" ]] \
          || {
            codex_radar_die "Duplicate MARKETING_VERSION"
            return 1
          }
        MARKETING_VERSION="$value"
        ;;
      BUILD_NUMBER)
        [[ -z "$BUILD_NUMBER" ]] \
          || {
            codex_radar_die "Duplicate BUILD_NUMBER"
            return 1
          }
        BUILD_NUMBER="$value"
        ;;
      *)
        codex_radar_die "Unexpected version key: $key"
        return 1
        ;;
    esac
  done < "$version_file"

  [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || {
      codex_radar_die "Invalid MARKETING_VERSION: $MARKETING_VERSION"
      return 1
    }
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || {
      codex_radar_die "Invalid BUILD_NUMBER: $BUILD_NUMBER"
      return 1
    }

  export MARKETING_VERSION BUILD_NUMBER
}

validate_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || {
      codex_radar_die "Invalid release tag: $tag"
      return 1
    }
  [[ "$tag" == "v${MARKETING_VERSION}" ]] \
    || {
      codex_radar_die "Tag $tag does not match v${MARKETING_VERSION}"
      return 1
    }
}

assert_commit_on_main() {
  local repository="$1"
  local commit="$2"
  local main_ref="$3"
  git -C "$repository" cat-file -e "${commit}^{commit}" 2>/dev/null \
    || {
      codex_radar_die "Unknown release commit: $commit"
      return 1
    }
  git -C "$repository" cat-file -e "${main_ref}^{commit}" 2>/dev/null \
    || {
      codex_radar_die "Unknown main ref: $main_ref"
      return 1
    }
  git -C "$repository" merge-base --is-ancestor "$commit" "$main_ref" \
    || {
      codex_radar_die "Release commit $commit is not contained in $main_ref"
      return 1
    }
}

validate_release_channel() {
  local signing_mode="$1"
  local prerelease="$2"
  [[ "$prerelease" == "true" || "$prerelease" == "false" ]] \
    || {
      codex_radar_die "RELEASE_PRERELEASE must be true or false"
      return 1
    }
  case "$signing_mode" in
    adhoc)
      [[ "$prerelease" == "true" ]] \
        || {
          codex_radar_die "Ad-hoc builds must remain pre-releases"
          return 1
        }
      ;;
    developer-id)
      ;;
    *)
      codex_radar_die "Unsupported SIGNING_MODE: $signing_mode"
      return 1
      ;;
  esac
}

require_developer_id_environment() {
  local variable=""
  for variable in \
    MACOS_SIGNING_IDENTITY \
    APP_STORE_CONNECT_API_KEY_P8 \
    APP_STORE_CONNECT_KEY_ID \
    APP_STORE_CONNECT_ISSUER_ID; do
    [[ -n "${!variable:-}" ]] \
      || {
        codex_radar_die "Missing $variable"
        return 1
      }
  done
}

release_asset_name() {
  printf '%s\n' "${APP_NAME}-v${MARKETING_VERSION}-macos-universal.zip"
}

release_checksum_name() {
  printf '%s\n' "$(release_asset_name).sha256"
}
```

Create `script/validate_release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TAG="${1:-}"
COMMIT="${2:-}"
MAIN_REF="${3:-}"

load_version "$ROOT_DIR/version.env"

if [[ -n "$TAG" ]]; then
  validate_release_tag "$TAG"
fi

if [[ -n "$COMMIT" || -n "$MAIN_REF" ]]; then
  [[ -n "$COMMIT" && -n "$MAIN_REF" ]] \
    || codex_radar_die "Commit and main ref must be provided together"
  assert_commit_on_main "$ROOT_DIR" "$COMMIT" "$MAIN_REF"
fi

printf 'Validated CodexRadar %s (%s)\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
```

- [ ] **Step 4: Run focused and syntax tests**

Run:

```bash
chmod +x script/lib/release_common.sh script/validate_release.sh
./script/tests/release_common_test.sh
bash -n script/lib/release_common.sh
bash -n script/validate_release.sh
./script/validate_release.sh
```

Expected:

```text
release_common_test: PASS
Validated CodexRadar 0.1.0 (1)
```

- [ ] **Step 5: Commit the metadata boundary**

```bash
git add version.env script/lib/release_common.sh script/validate_release.sh script/tests/release_common_test.sh
git commit -m "build: add release metadata validation"
```

### Task 2: App Bundle Assembly and Local Development Compatibility

**Files:**
- Create: `script/package_app.sh`
- Create: `script/sign_app.sh`
- Create: `script/verify_app.sh`
- Create: `script/tests/package_app_test.sh`
- Modify: `script/build_and_run.sh:1-119`

**Interfaces:**
- Consumes: `package_app.sh CONFIGURATION OUTPUT_APP ARCH...`, `SIGNING_MODE`, and `verify_app.sh APP EXPECTED_ARCH...`.
- Produces: an assembled app inside the repository, explicit signing, reusable verification, and unchanged local `run|debug|logs|telemetry|verify` commands.

- [ ] **Step 1: Write the failing host-architecture packaging test**

Create `script/tests/package_app_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$ROOT_DIR/tmp/package-app-test"
APP_BUNDLE="$TEST_DIR/CodexRadar.app"
ARCH="$(uname -m)"

rm -rf "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

"$ROOT_DIR/script/package_app.sh" debug "$APP_BUNDLE" "$ARCH"
SIGNING_MODE=adhoc "$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE"
SIGNING_MODE=adhoc "$ROOT_DIR/script/verify_app.sh" "$APP_BUNDLE" "$ARCH"

OTHER_ARCH="arm64"
if [[ "$ARCH" == "arm64" ]]; then
  OTHER_ARCH="x86_64"
fi
if SIGNING_MODE=adhoc \
  "$ROOT_DIR/script/verify_app.sh" \
  "$APP_BUNDLE" \
  "$ARCH" \
  "$OTHER_ARCH"; then
  echo "Expected verification to reject a missing architecture" >&2
  exit 1
fi

[[ -x "$APP_BUNDLE/Contents/MacOS/CodexRadar" ]]
[[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]
[[ -f "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png" ]]
[[ -d "$APP_BUNDLE/Contents/Resources/en.lproj" ]]
[[ -d "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj" ]]
[[ -d "$APP_BUNDLE/Contents/Resources/CodexRadar_CodexRadar.bundle" ]]

echo "package_app_test: PASS"
```

- [ ] **Step 2: Run the packaging test to verify it fails**

Run:

```bash
chmod +x script/tests/package_app_test.sh
./script/tests/package_app_test.sh
```

Expected: FAIL because `script/package_app.sh` does not exist.

- [ ] **Step 3: Implement focused assembly, signing, and verification scripts**

Create `script/package_app.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

CONFIGURATION="${1:-}"
OUTPUT_APP="${2:-}"
shift 2 || true
ARCHES=("$@")

[[ "$CONFIGURATION" == "debug" || "$CONFIGURATION" == "release" ]] \
  || codex_radar_die "Usage: package_app.sh debug|release OUTPUT_APP ARCH..."
[[ -n "$OUTPUT_APP" && ${#ARCHES[@]} -gt 0 ]] \
  || codex_radar_die "Usage: package_app.sh debug|release OUTPUT_APP ARCH..."

case "$OUTPUT_APP" in
  /*) ;;
  *) OUTPUT_APP="$ROOT_DIR/$OUTPUT_APP" ;;
esac

[[ "$OUTPUT_APP" == "$ROOT_DIR/"* ]] \
  || codex_radar_die "Output app must remain inside the repository"
[[ "$(basename "$OUTPUT_APP")" == "${APP_NAME}.app" ]] \
  || codex_radar_die "Output app must be named ${APP_NAME}.app"

load_version "$ROOT_DIR/version.env"

APP_CONTENTS="$OUTPUT_APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/CodexRadar/Resources/AppIcon.icns"
MENU_BAR_ICON_SOURCE="$ROOT_DIR/Sources/CodexRadar/Resources/MenuBarIcon.png"
COPYRIGHT="© 2026 Terence Tang. All rights reserved."

mkdir -p "$ROOT_DIR/tmp"
MANIFEST_DIR="$(mktemp -d "$ROOT_DIR/tmp/package-manifest.XXXXXX")"
trap 'rm -rf "$MANIFEST_DIR"' EXIT

resource_manifest() {
  local bundle="$1"
  local output="$2"
  (
    cd "$bundle"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      /usr/bin/shasum -a 256 "$file"
    done
  ) > "$output"
}

BINARIES=()
RESOURCE_BUNDLES=()
SEEN_ARCHES=" "

cd "$ROOT_DIR"
for arch in "${ARCHES[@]}"; do
  [[ "$arch" == "arm64" || "$arch" == "x86_64" ]] \
    || codex_radar_die "Unsupported architecture: $arch"
  [[ "$SEEN_ARCHES" != *" $arch "* ]] \
    || codex_radar_die "Duplicate architecture: $arch"
  SEEN_ARCHES="${SEEN_ARCHES}${arch} "

  scratch_path="$ROOT_DIR/.build/package/$CONFIGURATION/$arch"
  build_args=(
    swift build
    -c "$CONFIGURATION"
    --product "$APP_NAME"
    --arch "$arch"
    --scratch-path "$scratch_path"
  )
  "${build_args[@]}"
  bin_dir="$("${build_args[@]}" --show-bin-path)"
  binary="$bin_dir/$APP_NAME"
  resource_bundle="$bin_dir/$RESOURCE_BUNDLE_NAME"
  [[ -x "$binary" ]] || codex_radar_die "Missing binary for $arch: $binary"
  [[ -d "$resource_bundle" ]] \
    || codex_radar_die "Missing resource bundle for $arch: $resource_bundle"
  BINARIES+=("$binary")
  RESOURCE_BUNDLES+=("$resource_bundle")
done

base_manifest="$MANIFEST_DIR/${ARCHES[0]}.txt"
resource_manifest "${RESOURCE_BUNDLES[0]}" "$base_manifest"
for ((index = 1; index < ${#RESOURCE_BUNDLES[@]}; index++)); do
  candidate_manifest="$MANIFEST_DIR/${ARCHES[$index]}.txt"
  resource_manifest "${RESOURCE_BUNDLES[$index]}" "$candidate_manifest"
  cmp -s "$base_manifest" "$candidate_manifest" \
    || codex_radar_die "Resource bundles differ between architectures"
done

rm -rf "$OUTPUT_APP"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_BINARY"
else
  /usr/bin/lipo -create "${BINARIES[@]}" -output "$APP_BINARY"
fi
chmod +x "$APP_BINARY"

BASE_RESOURCE_BUNDLE="${RESOURCE_BUNDLES[0]}"
cp -R "$BASE_RESOURCE_BUNDLE" "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
cp "$MENU_BAR_ICON_SOURCE" "$APP_RESOURCES/MenuBarIcon.png"
cp -R "$BASE_RESOURCE_BUNDLE/en.lproj" "$APP_RESOURCES/en.lproj"
ZH_HANS_RESOURCES="$(
  find "$BASE_RESOURCE_BUNDLE" -maxdepth 1 -type d -iname 'zh-hans.lproj' -print -quit
)"
[[ -n "$ZH_HANS_RESOURCES" ]] \
  || codex_radar_die "Missing zh-Hans localization resources"
cp -R "$ZH_HANS_RESOURCES" "$APP_RESOURCES/zh-Hans.lproj"

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleName</key>
  <string>Codex Radar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST"
echo "Created $OUTPUT_APP"
```

Create `script/sign_app.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

APP_BUNDLE="${1:-}"
SIGNING_MODE="${SIGNING_MODE:-}"

[[ -d "$APP_BUNDLE" ]] || codex_radar_die "Missing app bundle: $APP_BUNDLE"

case "$SIGNING_MODE" in
  adhoc)
    /usr/bin/codesign --force --sign - "$APP_BUNDLE"
    ;;
  developer-id)
    [[ -n "${MACOS_SIGNING_IDENTITY:-}" ]] \
      || codex_radar_die "Missing MACOS_SIGNING_IDENTITY"
    /usr/bin/codesign \
      --force \
      --timestamp \
      --options runtime \
      --sign "$MACOS_SIGNING_IDENTITY" \
      "$APP_BUNDLE"
    ;;
  *)
    codex_radar_die "Unsupported SIGNING_MODE: $SIGNING_MODE"
    ;;
esac
```

Create `script/verify_app.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

APP_BUNDLE="${1:-}"
shift || true
EXPECTED_ARCHES=("$@")
SIGNING_MODE="${SIGNING_MODE:-}"

[[ -d "$APP_BUNDLE" && ${#EXPECTED_ARCHES[@]} -gt 0 ]] \
  || codex_radar_die "Usage: verify_app.sh APP EXPECTED_ARCH..."

load_version "$ROOT_DIR/version.env"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"

/usr/bin/plutil -lint "$INFO_PLIST"

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$INFO_PLIST"
}

[[ "$(plist_value CFBundleShortVersionString)" == "$MARKETING_VERSION" ]] \
  || codex_radar_die "Unexpected marketing version"
[[ "$(plist_value CFBundleVersion)" == "$BUILD_NUMBER" ]] \
  || codex_radar_die "Unexpected build number"
[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] \
  || codex_radar_die "Unexpected bundle identifier"
[[ "$(plist_value LSMinimumSystemVersion)" == "$MIN_SYSTEM_VERSION" ]] \
  || codex_radar_die "Unexpected minimum system version"

actual_arches="$(
  /usr/bin/lipo -archs "$APP_BINARY" \
    | tr ' ' '\n' \
    | LC_ALL=C sort \
    | paste -sd ' ' -
)"
expected_arches="$(
  printf '%s\n' "${EXPECTED_ARCHES[@]}" \
    | LC_ALL=C sort \
    | paste -sd ' ' -
)"
[[ "$actual_arches" == "$expected_arches" ]] \
  || codex_radar_die "Expected architectures '$expected_arches', found '$actual_arches'"

[[ -f "$APP_RESOURCES/AppIcon.icns" ]] || codex_radar_die "Missing AppIcon.icns"
[[ -f "$APP_RESOURCES/MenuBarIcon.png" ]] || codex_radar_die "Missing MenuBarIcon.png"
[[ -d "$APP_RESOURCES/en.lproj" ]] || codex_radar_die "Missing en.lproj"
[[ -d "$APP_RESOURCES/zh-Hans.lproj" ]] || codex_radar_die "Missing zh-Hans.lproj"
[[ -d "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME" ]] \
  || codex_radar_die "Missing SwiftPM resource bundle"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  /usr/sbin/spctl --assess --type execute --verbose "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
elif [[ "$SIGNING_MODE" != "adhoc" ]]; then
  codex_radar_die "Unsupported SIGNING_MODE: $SIGNING_MODE"
fi

echo "Verified $APP_BUNDLE"
```

Replace `script/build_and_run.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexRadar"
BUNDLE_ID="com.terence.codex-radar"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HOST_ARCH="$(uname -m)"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

"$ROOT_DIR/script/package_app.sh" debug "$APP_BUNDLE" "$HOST_ARCH"
SIGNING_MODE=adhoc "$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    SIGNING_MODE=adhoc "$ROOT_DIR/script/verify_app.sh" "$APP_BUNDLE" "$HOST_ARCH"
    open_app
    for _ in 1 2 3 4 5; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "$APP_NAME did not stay running" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 4: Run host packaging, Swift tests, and local compatibility checks**

Run:

```bash
chmod +x \
  script/package_app.sh \
  script/sign_app.sh \
  script/verify_app.sh \
  script/build_and_run.sh
./script/tests/package_app_test.sh
swift test
./script/build_and_run.sh --verify
```

Expected:

```text
package_app_test: PASS
```

Expected additionally: all Swift tests pass, `dist/CodexRadar.app` verifies, launches, and remains running for the five-second probe.

- [ ] **Step 5: Commit the shared app assembly path**

```bash
git add script/package_app.sh script/sign_app.sh script/verify_app.sh script/build_and_run.sh script/tests/package_app_test.sh
git commit -m "build: extract reusable app packaging"
```

### Task 3: Universal 2 Release Packaging and Notarization Boundary

**Files:**
- Create: `script/package_release.sh`
- Create: `script/tests/package_release_test.sh`

**Interfaces:**
- Consumes: `SIGNING_MODE`, `RELEASE_PRERELEASE`, optional Developer ID environment, and an output directory inside the repository.
- Produces: `CodexRadar-v${MARKETING_VERSION}-macos-universal.zip` plus its `.sha256` file; Developer ID mode signs, submits, staples, and verifies before final ZIP creation.

- [ ] **Step 1: Write the failing Universal 2 release-package test**

Create `script/tests/package_release_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

OUTPUT_DIR="$ROOT_DIR/tmp/package-release-test"
EXTRACT_DIR="$ROOT_DIR/tmp/package-release-extract"
rm -rf "$OUTPUT_DIR" "$EXTRACT_DIR"
trap 'rm -rf "$OUTPUT_DIR" "$EXTRACT_DIR"' EXIT

if (
  unset MACOS_SIGNING_IDENTITY
  unset APP_STORE_CONNECT_API_KEY_P8
  unset APP_STORE_CONNECT_KEY_ID
  unset APP_STORE_CONNECT_ISSUER_ID
  SIGNING_MODE=developer-id \
    RELEASE_PRERELEASE=false \
    "$ROOT_DIR/script/package_release.sh" "$OUTPUT_DIR"
); then
  echo "Expected developer-id packaging to reject missing credentials" >&2
  exit 1
fi

SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
  "$ROOT_DIR/script/package_release.sh" "$OUTPUT_DIR"

load_version "$ROOT_DIR/version.env"
ASSET="$OUTPUT_DIR/$(release_asset_name)"
CHECKSUM="$OUTPUT_DIR/$(release_checksum_name)"
[[ -f "$ASSET" ]]
[[ -f "$CHECKSUM" ]]

(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ASSET" "$EXTRACT_DIR"
[[ "$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')" == "1" ]]
SIGNING_MODE=adhoc \
  "$ROOT_DIR/script/verify_app.sh" \
  "$EXTRACT_DIR/CodexRadar.app" \
  arm64 \
  x86_64

echo "package_release_test: PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
chmod +x script/tests/package_release_test.sh
./script/tests/package_release_test.sh
```

Expected: FAIL because `script/package_release.sh` does not exist.

- [ ] **Step 3: Implement release packaging with an explicit notarization branch**

Create `script/package_release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

OUTPUT_DIR="${1:-$ROOT_DIR/dist/release}"
SIGNING_MODE="${SIGNING_MODE:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-}"

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR" ;;
esac

[[ "$OUTPUT_DIR" == "$ROOT_DIR/"* ]] \
  || codex_radar_die "Release output must remain inside the repository"

load_version "$ROOT_DIR/version.env"
validate_release_channel "$SIGNING_MODE" "$RELEASE_PRERELEASE"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  require_developer_id_environment
fi

mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/tmp"
TEMP_DIR="$(mktemp -d "$ROOT_DIR/tmp/package-release.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
ASSET="$OUTPUT_DIR/$(release_asset_name)"
CHECKSUM="$OUTPUT_DIR/$(release_checksum_name)"

notarize_app() {
  local app_bundle="$1"
  local api_key_path="$TEMP_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  local submission_zip="$TEMP_DIR/${APP_NAME}-notarization.zip"

  (
    umask 077
    printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" > "$api_key_path"
  )
  /usr/bin/ditto --norsrc -c -k --keepParent "$app_bundle" "$submission_zip"
  /usr/bin/xcrun notarytool submit "$submission_zip" \
    --key "$api_key_path" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  /usr/bin/xcrun stapler staple "$app_bundle"
}

"$ROOT_DIR/script/package_app.sh" \
  release \
  "$APP_BUNDLE" \
  arm64 \
  x86_64
SIGNING_MODE="$SIGNING_MODE" "$ROOT_DIR/script/sign_app.sh" "$APP_BUNDLE"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  notarize_app "$APP_BUNDLE"
fi

SIGNING_MODE="$SIGNING_MODE" \
  "$ROOT_DIR/script/verify_app.sh" \
  "$APP_BUNDLE" \
  arm64 \
  x86_64

rm -f "$ASSET" "$CHECKSUM"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ASSET"

EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
/usr/bin/ditto -x -k "$ASSET" "$EXTRACT_DIR"
ENTRY_COUNT="$(
  find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -print \
    | wc -l \
    | tr -d '[:space:]'
)"
[[ "$ENTRY_COUNT" == "1" && -d "$EXTRACT_DIR/$APP_NAME.app" ]] \
  || codex_radar_die "Release ZIP must contain exactly one top-level app"

SIGNING_MODE="$SIGNING_MODE" \
  "$ROOT_DIR/script/verify_app.sh" \
  "$EXTRACT_DIR/$APP_NAME.app" \
  arm64 \
  x86_64

(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ASSET")" > "$(basename "$CHECKSUM")"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

printf 'Created %s\n' "$ASSET"
printf 'Created %s\n' "$CHECKSUM"
```

- [ ] **Step 4: Run the Universal 2 integration test and inspect the artifact**

Run:

```bash
chmod +x script/package_release.sh
./script/tests/package_release_test.sh
```

Expected:

```text
package_release_test: PASS
```

The integration test extracts the ZIP and verifies the sorted architecture set as `arm64 x86_64`.

- [ ] **Step 5: Commit the Universal 2 release package**

```bash
git add script/package_release.sh script/tests/package_release_test.sh
git commit -m "build: package universal macOS releases"
```

### Task 4: Draft-Safe GitHub Release Publication

**Files:**
- Create: `.github/release-notes-adhoc.md`
- Create: `script/publish_release.sh`
- Create: `script/tests/publish_release_test.sh`

**Interfaces:**
- Consumes: `publish_release.sh TAG ASSET CHECKSUM`, `GH_TOKEN`, `SIGNING_MODE`, and `RELEASE_PRERELEASE`.
- Produces: a new or reused Draft Release, clobbered same-name Draft assets, refusal to overwrite public releases, and final Pre-release publication.

- [ ] **Step 1: Write the failing fake-GitHub release-state test**

Create `script/tests/publish_release_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-publish-release.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
FAKE_GH="$TEST_DIR/gh"
GH_LOG="$TEST_DIR/gh.log"

cat > "$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
if [[ "$1" == "release" && "$2" == "view" ]]; then
  case "$FAKE_GH_STATE" in
    missing) exit 1 ;;
    draft) printf 'true\n' ;;
    public) printf 'false\n' ;;
    *) exit 2 ;;
  esac
fi
FAKE
chmod +x "$FAKE_GH"

load_version "$ROOT_DIR/version.env"
ASSET="$TEST_DIR/$(release_asset_name)"
CHECKSUM="$TEST_DIR/$(release_checksum_name)"
printf 'asset\n' > "$ASSET"
(
  cd "$TEST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ASSET")" > "$(basename "$CHECKSUM")"
)

run_publish() {
  FAKE_GH_STATE="$1" \
  GH_LOG="$GH_LOG" \
  GH_BIN="$FAKE_GH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=true \
    "$ROOT_DIR/script/publish_release.sh" \
    "v$MARKETING_VERSION" \
    "$ASSET" \
    "$CHECKSUM"
}

: > "$GH_LOG"
run_publish missing
grep -Fq "release create v$MARKETING_VERSION" "$GH_LOG"
grep -Fq "release upload v$MARKETING_VERSION" "$GH_LOG"
grep -Fq "release edit v$MARKETING_VERSION --draft=false --prerelease" "$GH_LOG"

: > "$GH_LOG"
run_publish draft
if grep -Fq "release create" "$GH_LOG"; then
  echo "Existing drafts must be reused" >&2
  exit 1
fi
grep -Fq "release upload v$MARKETING_VERSION" "$GH_LOG"

: > "$GH_LOG"
if run_publish public; then
  echo "Published releases must not be overwritten" >&2
  exit 1
fi
if grep -Fq "release upload" "$GH_LOG"; then
  echo "Published release guard ran too late" >&2
  exit 1
fi

if FAKE_GH_STATE=missing \
  GH_LOG="$GH_LOG" \
  GH_BIN="$FAKE_GH" \
  SIGNING_MODE=adhoc \
  RELEASE_PRERELEASE=false \
    "$ROOT_DIR/script/publish_release.sh" \
    "v$MARKETING_VERSION" \
    "$ASSET" \
    "$CHECKSUM"; then
  echo "Ad-hoc stable releases must be rejected" >&2
  exit 1
fi

echo "publish_release_test: PASS"
```

- [ ] **Step 2: Run the fake-GitHub test to verify it fails**

Run:

```bash
chmod +x script/tests/publish_release_test.sh
./script/tests/publish_release_test.sh
```

Expected: FAIL because `script/publish_release.sh` does not exist.

- [ ] **Step 3: Add the fixed warning and Draft-safe publisher**

Create `.github/release-notes-adhoc.md` with exactly this Markdown:

> [!WARNING]
> This pre-release is ad-hoc signed and has not been notarized by Apple. On first launch, right-click CodexRadar.app in Finder, choose Open, and confirm the prompt. Do not install this build if you require a notarized distribution.

Create `script/publish_release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

TAG="${1:-}"
ASSET="${2:-}"
CHECKSUM="${3:-}"
SIGNING_MODE="${SIGNING_MODE:-}"
RELEASE_PRERELEASE="${RELEASE_PRERELEASE:-}"
GH_BIN="${GH_BIN:-gh}"
NOTES_FILE="$ROOT_DIR/.github/release-notes-adhoc.md"

load_version "$ROOT_DIR/version.env"
validate_release_tag "$TAG"
validate_release_channel "$SIGNING_MODE" "$RELEASE_PRERELEASE"

[[ -f "$ASSET" ]] || codex_radar_die "Missing release asset: $ASSET"
[[ -f "$CHECKSUM" ]] || codex_radar_die "Missing checksum: $CHECKSUM"
[[ "$(basename "$ASSET")" == "$(release_asset_name)" ]] \
  || codex_radar_die "Unexpected release asset name"
[[ "$(basename "$CHECKSUM")" == "$(release_checksum_name)" ]] \
  || codex_radar_die "Unexpected checksum name"
if [[ "$SIGNING_MODE" == "adhoc" ]]; then
  [[ -f "$NOTES_FILE" ]] || codex_radar_die "Missing release notes preamble"
fi
[[ "$(dirname "$ASSET")" == "$(dirname "$CHECKSUM")" ]] \
  || codex_radar_die "Release asset and checksum must share a directory"
(
  cd "$(dirname "$ASSET")"
  /usr/bin/shasum -a 256 --check "$(basename "$CHECKSUM")"
)

RELEASE_STATE=""
if RELEASE_STATE="$(
  "$GH_BIN" release view "$TAG" --json isDraft --jq '.isDraft' 2>/dev/null
)"; then
  [[ "$RELEASE_STATE" == "true" ]] \
    || codex_radar_die "Release $TAG is already public and cannot be overwritten"
else
  CREATE_ARGS=(
    release create "$TAG"
    --draft
    --verify-tag
    --title "Codex Radar $TAG"
    --generate-notes
  )
  if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    CREATE_ARGS+=(--notes "$(cat "$NOTES_FILE")")
  fi
  "$GH_BIN" "${CREATE_ARGS[@]}"
fi

"$GH_BIN" release upload "$TAG" "$ASSET" "$CHECKSUM" --clobber

if [[ "$RELEASE_PRERELEASE" == "true" ]]; then
  "$GH_BIN" release edit "$TAG" --draft=false --prerelease
else
  "$GH_BIN" release edit "$TAG" --draft=false --prerelease=false
fi
```

- [ ] **Step 4: Run publisher tests and shell syntax checks**

Run:

```bash
chmod +x script/publish_release.sh
./script/tests/publish_release_test.sh
bash -n script/publish_release.sh
```

Expected:

```text
publish_release_test: PASS
```

- [ ] **Step 5: Commit the GitHub Release state machine**

```bash
git add .github/release-notes-adhoc.md script/publish_release.sh script/tests/publish_release_test.sh
git commit -m "build: add draft-safe release publishing"
```

### Task 5: Pull Request and Main-Branch CI

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: scripts and tests from Tasks 1–4.
- Produces: one macOS CI job for shell syntax, shell helper tests, Swift tests, and host-architecture app packaging.

- [ ] **Step 1: Record the absent-workflow failure**

Run:

```bash
test -f .github/workflows/ci.yml
```

Expected: FAIL because `.github/workflows/ci.yml` does not exist.

- [ ] **Step 2: Add the focused macOS CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - name: Validate shell syntax
        shell: bash
        run: |
          set -euo pipefail
          while IFS= read -r -d '' script_file; do
            bash -n "$script_file"
          done < <(find script -type f -name '*.sh' -print0)

      - name: Test release helpers
        run: |
          ./script/tests/release_common_test.sh
          ./script/tests/publish_release_test.sh

      - name: Swift tests
        run: swift test

      - name: Package host application
        run: ./script/tests/package_app_test.sh
```

- [ ] **Step 3: Parse the workflow and run its commands locally**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml"); puts "ci.yml: PASS"'
while IFS= read -r -d '' script_file; do bash -n "$script_file"; done < <(find script -type f -name '*.sh' -print0)
./script/tests/release_common_test.sh
./script/tests/publish_release_test.sh
swift test
./script/tests/package_app_test.sh
```

Expected:

```text
ci.yml: PASS
release_common_test: PASS
publish_release_test: PASS
package_app_test: PASS
```

Expected additionally: all Swift tests pass.

- [ ] **Step 4: Commit CI**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: test and package the macOS app"
```

### Task 6: Tag Release and Manual Dry-Run Workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `script/tests/workflow_contract_test.sh`

**Interfaces:**
- Consumes: `v*` tags or `workflow_dispatch`, `release` Environment secrets, package scripts, publisher, and pinned Actions.
- Produces: seven-day Universal 2 Actions Artifacts for both triggers and a GitHub Pre-release only for tag pushes.

- [ ] **Step 1: Write the failing workflow contract test**

Create `script/tests/workflow_contract_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$CI_WORKFLOW"
ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$RELEASE_WORKFLOW"

grep -Fq "branches: [main]" "$CI_WORKFLOW"
grep -Fq "tags: ['v*']" "$RELEASE_WORKFLOW"
grep -Fq "workflow_dispatch:" "$RELEASE_WORKFLOW"
grep -Fq "SIGNING_MODE: adhoc" "$RELEASE_WORKFLOW"
grep -Fq 'RELEASE_PRERELEASE: "true"' "$RELEASE_WORKFLOW"
grep -Fq "contents: write" "$RELEASE_WORKFLOW"
grep -Fq "./script/package_release.sh" "$RELEASE_WORKFLOW"
grep -Fq "./script/publish_release.sh" "$RELEASE_WORKFLOW"
grep -Fq "github.event_name == 'push'" "$RELEASE_WORKFLOW"
grep -Fq "retention-days: 7" "$RELEASE_WORKFLOW"

echo "workflow_contract_test: PASS"
```

- [ ] **Step 2: Run the contract test to verify it fails**

Run:

```bash
chmod +x script/tests/workflow_contract_test.sh
./script/tests/workflow_contract_test.sh
```

Expected: FAIL because `.github/workflows/release.yml` does not exist.

- [ ] **Step 3: Add the tag and dry-run workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

env:
  SIGNING_MODE: adhoc
  RELEASE_PRERELEASE: "true"

jobs:
  release:
    runs-on: macos-15
    timeout-minutes: 60
    environment: release
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          fetch-depth: 0

      - name: Validate release metadata
        id: metadata
        shell: bash
        run: |
          set -euo pipefail
          if [[ "$GITHUB_EVENT_NAME" == "push" ]]; then
            git fetch origin main:refs/remotes/origin/main
            ./script/validate_release.sh \
              "$GITHUB_REF_NAME" \
              "$GITHUB_SHA" \
              refs/remotes/origin/main
          else
            ./script/validate_release.sh
          fi
          version="$(awk -F= '$1 == "MARKETING_VERSION" { print $2 }' version.env)"
          echo "version=$version" >> "$GITHUB_OUTPUT"

      - name: Validate shell syntax
        shell: bash
        run: |
          set -euo pipefail
          while IFS= read -r -d '' script_file; do
            bash -n "$script_file"
          done < <(find script -type f -name '*.sh' -print0)

      - name: Test release helpers
        run: |
          ./script/tests/release_common_test.sh
          ./script/tests/publish_release_test.sh
          ./script/tests/workflow_contract_test.sh

      - name: Swift tests
        run: swift test

      - name: Import Developer ID certificate
        if: env.SIGNING_MODE == 'developer-id'
        shell: bash
        env:
          MACOS_CERTIFICATE_P12: ${{ secrets.MACOS_CERTIFICATE_P12 }}
          MACOS_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
        run: |
          set -euo pipefail
          : "${MACOS_CERTIFICATE_P12:?Missing MACOS_CERTIFICATE_P12}"
          : "${MACOS_CERTIFICATE_PASSWORD:?Missing MACOS_CERTIFICATE_PASSWORD}"

          certificate_path="$RUNNER_TEMP/codex-radar-certificate.p12"
          keychain_path="$RUNNER_TEMP/codex-radar-signing.keychain-db"
          keychain_password="$(openssl rand -hex 32)"
          echo "::add-mask::$keychain_password"

          printf '%s' "$MACOS_CERTIFICATE_P12" | /usr/bin/base64 -D > "$certificate_path"
          security create-keychain -p "$keychain_password" "$keychain_path"
          security set-keychain-settings -lut 21600 "$keychain_path"
          security unlock-keychain -p "$keychain_password" "$keychain_path"
          security import "$certificate_path" \
            -k "$keychain_path" \
            -P "$MACOS_CERTIFICATE_PASSWORD" \
            -T /usr/bin/codesign
          security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s \
            -k "$keychain_password" \
            "$keychain_path"
          security list-keychains -d user -s "$keychain_path"

          identity="$(
            security find-identity -v -p codesigning "$keychain_path" \
              | awk '/Developer ID Application/ { print $2; exit }'
          )"
          [[ -n "$identity" ]]
          echo "MACOS_SIGNING_IDENTITY=$identity" >> "$GITHUB_ENV"
          echo "SIGNING_KEYCHAIN_PATH=$keychain_path" >> "$GITHUB_ENV"
          rm -f "$certificate_path"

      - name: Package Universal 2 release
        env:
          APP_STORE_CONNECT_API_KEY_P8: ${{ secrets.APP_STORE_CONNECT_API_KEY_P8 }}
          APP_STORE_CONNECT_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
        run: ./script/package_release.sh dist/release

      - name: Upload workflow artifact
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: codex-radar-v${{ steps.metadata.outputs.version }}-macos-universal
          path: |
            dist/release/CodexRadar-v${{ steps.metadata.outputs.version }}-macos-universal.zip
            dist/release/CodexRadar-v${{ steps.metadata.outputs.version }}-macos-universal.zip.sha256
          retention-days: 7
          if-no-files-found: error

      - name: Publish GitHub release
        if: github.event_name == 'push'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          ./script/publish_release.sh \
            "$GITHUB_REF_NAME" \
            "dist/release/CodexRadar-v${{ steps.metadata.outputs.version }}-macos-universal.zip" \
            "dist/release/CodexRadar-v${{ steps.metadata.outputs.version }}-macos-universal.zip.sha256"

      - name: Clean signing keychain
        if: always() && env.SIGNING_MODE == 'developer-id'
        shell: bash
        run: |
          set -euo pipefail
          if [[ -n "${SIGNING_KEYCHAIN_PATH:-}" ]]; then
            security delete-keychain "$SIGNING_KEYCHAIN_PATH" || true
          fi
          rm -f "$RUNNER_TEMP/codex-radar-certificate.p12"
```

- [ ] **Step 4: Validate workflow syntax, contracts, and local release packaging**

Run:

```bash
chmod +x script/tests/workflow_contract_test.sh
./script/tests/workflow_contract_test.sh
./script/tests/release_common_test.sh
./script/tests/publish_release_test.sh
SIGNING_MODE=adhoc RELEASE_PRERELEASE=true ./script/package_release.sh tmp/release-workflow-dry-run
```

Expected:

```text
workflow_contract_test: PASS
release_common_test: PASS
publish_release_test: PASS
```

Expected additionally: `tmp/release-workflow-dry-run` contains the Universal 2 ZIP and verified checksum. No GitHub Release is created by these local commands.

- [ ] **Step 5: Commit the release workflow**

```bash
git add .github/workflows/release.yml script/tests/workflow_contract_test.sh
git commit -m "ci: publish tagged macOS pre-releases"
```

### Task 7: Release Documentation and Full Verification

**Files:**
- Modify: `README.md:18-34`

**Interfaces:**
- Consumes: the completed local scripts and GitHub workflows.
- Produces: a documented release procedure and final evidence without creating a tag or external Release.

- [ ] **Step 1: Add exact release operating instructions**

Append a `## 发布` section to `README.md` after the existing testing section. The section must state all of the following in Chinese:

- `version.env` must be updated and committed before release.
- `MARKETING_VERSION` uses `MAJOR.MINOR.PATCH`; `BUILD_NUMBER` is a positive integer.
- GitHub Actions `Release` can be run manually to produce a seven-day Artifact without creating a Release.
- A tag such as `v0.1.0` must point to a commit already contained in `main`.
- Pushing that tag creates an ad-hoc signed, non-notarized GitHub Pre-release.
- Published tags and Releases are never overwritten automatically.
- Developer ID distribution remains disabled until the Apple Developer Program credentials listed in the design are configured.

Include these exact command blocks:

```bash
SIGNING_MODE=adhoc RELEASE_PRERELEASE=true \
  ./script/package_release.sh dist/release
```

```bash
git tag -a v0.1.0 -m "CodexRadar v0.1.0"
git push origin v0.1.0
```

- [ ] **Step 2: Run the complete local verification suite**

Run:

```bash
git diff --check
while IFS= read -r -d '' script_file; do bash -n "$script_file"; done < <(find script -type f -name '*.sh' -print0)
./script/tests/release_common_test.sh
./script/tests/publish_release_test.sh
./script/tests/workflow_contract_test.sh
./script/tests/package_app_test.sh
swift test
SIGNING_MODE=adhoc RELEASE_PRERELEASE=true ./script/package_release.sh tmp/final-release-verification
(
  cd tmp/final-release-verification
  /usr/bin/shasum -a 256 --check CodexRadar-v0.1.0-macos-universal.zip.sha256
)
```

Expected:

```text
release_common_test: PASS
publish_release_test: PASS
workflow_contract_test: PASS
package_app_test: PASS
CodexRadar-v0.1.0-macos-universal.zip: OK
```

Expected additionally: all Swift tests pass and no command creates or pushes a tag.

- [ ] **Step 3: Inspect the final app metadata and architecture**

Run:

```bash
rm -rf tmp/final-release-extract
mkdir -p tmp/final-release-extract
/usr/bin/ditto -x -k \
  tmp/final-release-verification/CodexRadar-v0.1.0-macos-universal.zip \
  tmp/final-release-extract
/usr/bin/plutil -p tmp/final-release-extract/CodexRadar.app/Contents/Info.plist
/usr/bin/lipo -archs tmp/final-release-extract/CodexRadar.app/Contents/MacOS/CodexRadar
/usr/bin/codesign --verify --deep --strict --verbose=2 tmp/final-release-extract/CodexRadar.app
```

Expected plist values:

```text
"CFBundleIdentifier" => "com.terence.codex-radar"
"CFBundleShortVersionString" => "0.1.0"
"CFBundleVersion" => "1"
"LSMinimumSystemVersion" => "14.0"
```

Expected architectures: `arm64 x86_64` in either order. Expected signing result: exit status `0`.

- [ ] **Step 4: Commit the operating documentation**

```bash
git add README.md
git commit -m "docs: document the release workflow"
```

## Post-Implementation GitHub Checks

These checks occur after the implementation branch is reviewed and pushed; they do not create a public Release:

1. Open Actions → Release → Run workflow on `main`.
2. Confirm the job completes without requesting Apple credentials while `SIGNING_MODE` is `adhoc`.
3. Download the seven-day Artifact.
4. Verify the Artifact contains exactly the ZIP and `.sha256` file.
5. Verify no GitHub Release was created by `workflow_dispatch`.

The first real tag remains an explicit operator action. Before pushing it, verify `version.env`, the `main` commit, and the successful manual dry run.

Because the repository currently has no Apple Developer Program credentials, the Developer ID branch is limited to syntax checks and fail-closed credential tests in this implementation cycle. Its first end-to-end signing and notarization run must occur only after all five `release` Environment secrets are configured.
