# GitHub Release 自动化设计

## 背景

CodexRadar 当前通过 `script/build_and_run.sh` 在本地构建应用包。该脚本同时承担编译、生成 `Info.plist`、复制资源、ad-hoc 签名和启动应用等职责。版本号固定为 `0.1.0 (1)`，仓库尚无 tag、GitHub Release 或 GitHub Actions 配置。

本设计参考 CodexBar 的 GitHub Actions，但不直接复制其三个 workflow：

- `ci.yml` 依赖 CodexBar 专用的测试门禁、lint、测试分片和 Linux CLI 构建脚本。
- `release-cli.yml` 发布跨平台 `CodexBarCLI`，由已经发布的 GitHub Release 触发，不负责 macOS 应用签名、公证或创建 Release。
- `upstream-monitor.yml` 用于监控外部仓库并创建 Issue，与应用发布无关。

CodexBar 的 macOS 应用发布能力主要位于其本地打包、签名和公证脚本中。因此，CodexRadar 应借鉴职责划分和安全约束，而不是复制项目专用实现。

## 目标

首期建立一条可由 `v*` tag 触发的 GitHub Release 流水线：

- 构建同时支持 `arm64` 和 `x86_64` 的 Universal 2 应用。
- 使用仓库中的统一版本配置生成应用元数据。
- 在没有付费 Apple Developer Program 账号时使用 ad-hoc 签名。
- 将未公证版本发布为 GitHub Pre-release，并明确告知 Gatekeeper 限制。
- 支持不创建 Release 的手动 dry run。
- 为未来 Developer ID 签名和 Apple 公证保留稳定、显式的扩展边界。

## 非目标

首期不实现以下能力：

- Sparkle 自动更新和 appcast。
- Homebrew Cask。
- 自动修改、提交或推送下一个版本号。
- 自动创建、删除或强制覆盖 Git tag。
- dSYM 发布或崩溃符号服务。
- Linux 构建或 CLI 产物。
- 根据 secrets 是否存在自动切换签名模式。

## 关键决策

### 脚本优先，Workflow 负责编排

构建、应用组装、签名和验证必须在仓库脚本中实现。GitHub Actions 仅负责事件触发、权限控制、调用脚本、保存 Artifact 和创建 Release。

这保证本地与 CI 共享同一条产物路径，也让未来的 Developer ID 签名只影响签名和公证阶段。

### 版本配置

新增 `version.env`，包含：

- `MARKETING_VERSION`：严格使用 `MAJOR.MINOR.PATCH` 格式。
- `BUILD_NUMBER`：正整数。

`version.env` 是应用版本的唯一配置来源。本地打包和 CI 均读取该文件。发布 tag 必须严格等于 `v${MARKETING_VERSION}`。

首个发布版本保持为 `0.1.0 (1)`。准备后续版本时，开发者先提交 `version.env` 的变更，再在该提交进入 `main` 后创建 tag。

### 发布渠道

当前 `SIGNING_MODE` 显式设为 `adhoc`：

- tag 构建只能发布为 Pre-release。
- Release 说明顶部必须标注该应用未经过 Apple 公证。
- Workflow 不得因为检测到部分凭据而改变发布类型。

未来取得 Apple Developer Program 资格后，通过可审阅的配置变更将 `SIGNING_MODE` 改为 `developer-id`，同时启用公证并将 Release 改为正式发布。

## 组件设计

### `version.env`

只保存版本和构建号，不包含密钥、签名身份或环境相关路径。

### `script/package_app.sh`

负责生成完整但尚未执行发布签名的应用包：

1. 读取并验证 `version.env`。
2. 根据调用者传入的架构集合执行构建；发布调用必须传入 `arm64` 和 `x86_64`，本地开发调用默认使用当前主机架构。
3. 在相互隔离的 SwiftPM scratch path 中保存各架构产物。
4. 请求多个架构时校验各构建的资源集合一致。
5. 请求多个架构时使用 `lipo` 合并主程序。
6. 复制图标、本地化资源和 SwiftPM 资源。
7. 根据版本配置生成 `Info.plist`。
8. 将应用组装到调用者指定的输出目录。

脚本不得启动应用、创建 ZIP、访问 GitHub 或读取发布 secrets。

### `script/sign_app.sh`

通过显式的 `SIGNING_MODE` 参数选择签名行为：

- `adhoc`：使用 ad-hoc identity 签名完整应用包。
- `developer-id`：使用 Developer ID、timestamp 和 hardened runtime 签名；缺少任一必要输入时立即失败。

当前 bundle 不包含 Helper、Framework 或 Extension，因此首期只处理主应用。未来新增嵌套可执行代码时，必须由内到外扩展签名顺序，不能依赖 `--deep` 代替正确签名。

### `script/verify_app.sh`

对组装和签名后的应用执行以下检查：

- `Info.plist` 可以被 `plutil` 解析。
- `CFBundleShortVersionString` 与 `MARKETING_VERSION` 一致。
- `CFBundleVersion` 与 `BUILD_NUMBER` 一致。
- `CFBundleIdentifier` 为 `com.terence.codex-radar`。
- `LSMinimumSystemVersion` 为 `14.0`。
- 主程序包含且仅包含调用者声明的预期架构；发布验证必须声明 `arm64` 和 `x86_64`。
- 英文和简体中文资源完整。
- `codesign --verify --deep --strict` 成功。

在 Developer ID 模式下，额外执行 Gatekeeper 和公证票据验证。

### `script/package_release.sh`

编排本地发布产物的生成：

1. 调用 `package_app.sh`。
2. 调用 `sign_app.sh`。
3. Developer ID 模式下提交公证并 staple 票据。
4. 调用 `verify_app.sh`。
5. 使用系统 `ditto` 生成只包含一个顶层 `CodexRadar.app` 的 ZIP。
6. 解压到临时目录并再次检查结构和签名。
7. 生成 SHA-256 文件。

输出文件名为：

- `CodexRadar-v${MARKETING_VERSION}-macos-universal.zip`
- `CodexRadar-v${MARKETING_VERSION}-macos-universal.zip.sha256`

### `script/build_and_run.sh`

继续作为本地开发入口，但不再独立维护 `Info.plist` 和资源复制逻辑。它复用应用组装能力，并默认只构建当前主机架构，避免每次本地启动都生成 Universal 2 产物。

现有 `run`、`debug`、`logs`、`telemetry` 和 `verify` 行为保持兼容。

### `.github/workflows/ci.yml`

在 pull request 和 `main` push 上运行：

- checkout，且第三方 Action 固定到完整 commit SHA。
- `swift test`。
- 当前 runner 架构的应用构建。
- 所有发布脚本的 `bash -n` 检查。

Workflow 使用并发组，同一分支的新运行会取消旧运行。首期不加入路径过滤、测试分片、Linux runner 或复杂聚合 job。

### `.github/workflows/release.yml`

支持两种事件：

- `push` 到 `v*` tag：构建并创建 GitHub Release。
- `workflow_dispatch`：执行相同的 Universal 2 构建、签名和验证，但只保存 Actions Artifact，不创建 Release。

Workflow 只授予创建 Release 所需的 `contents: write` 权限。手动 dry run 的产物包含 ZIP 和 checksum，并使用有限保留期。

## 发布数据流

Tag 发布执行以下步骤：

1. 以完整历史 checkout tag 对应提交。
2. 验证 tag 格式、`version.env` 和 build number。
3. 验证 tag 对应提交是 `main` 的祖先。
4. 重新运行 `swift test`。
5. 生成、签名和验证 Universal 2 发布产物。
6. 创建隐藏的 Draft Release，并结合固定的安全提示与 GitHub 自动生成的 release notes。
7. 上传 ZIP 和 checksum。
8. 资产全部上传成功后，将 Draft 发布为 Pre-release。

只有最后三个步骤访问 GitHub Release。构建、测试或验证失败不得创建 Release。

## 失败处理与可重跑性

- 构建、测试、签名或验证失败：终止运行，不创建 Release。
- 上传失败：保留 Draft，避免向普通用户暴露不完整发布。
- 同一 tag 存在 Draft：复用 Draft，并使用 `--clobber` 替换同名资产。
- 同一 tag 已存在公开 Release：直接失败，不覆盖已发布资产。
- 不存在于 `main` 的 tag：直接失败。
- 不自动删除 tag、Release、Draft 或历史资产。
- Developer ID 模式缺少任一凭据：直接失败，禁止回退到 ad-hoc。

可重跑性保证发布状态和产物内容符合相同约束，但不承诺 ZIP 逐字节可复现，因为编译产物和归档元数据可能包含时间信息。

## Developer ID 与公证升级路径

未来在 GitHub `release` Environment 中保存：

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

Workflow 在临时 keychain 中导入证书，并在成功、失败或取消时清理 keychain、API key 文件和临时目录。日志不得输出密钥内容。

Developer ID 模式执行：

1. 使用 Developer ID、timestamp 和 hardened runtime 签名。
2. 用 `notarytool submit --wait` 提交临时归档。
3. 对应用执行 staple。
4. 执行 `codesign --verify --deep --strict`。
5. 执行 `spctl --assess --type execute`。
6. 执行 `stapler validate`。
7. 验证成功后才创建最终发布 ZIP。

该升级不改变版本、构建、应用组装、资产命名或 Release 创建边界。

## 验证策略

### 常规 CI

- Swift 单元测试全部成功。
- 应用 target 可以在当前 runner 架构编译。
- Shell 脚本通过语法检查。

### 发布 dry run

- 两个架构均成功构建。
- `lipo -archs` 结果包含且仅包含 `arm64`、`x86_64`。
- 两个架构的资源集合一致。
- 应用元数据与 `version.env` 一致。
- 应用签名验证成功。
- ZIP 顶层结构正确。
- checksum 可以通过 `shasum -a 256 --check` 验证。

### 发布边界测试

发布校验脚本需要覆盖：

- tag 与 `version.env` 不一致时失败。
- 非 SemVer tag 时失败。
- build number 不是正整数时失败。
- 缺少任一目标架构时失败。
- 已存在公开 Release 时拒绝覆盖。
- 已存在 Draft 时允许安全重跑。
- Developer ID 模式缺少任一必要输入时失败。
- ad-hoc 模式不能发布为正式 Release。

## 验收标准

实现完成后应满足：

1. PR 和 `main` push 会运行精简的 macOS CI。
2. 手动运行 release workflow 会得到经过验证的 Universal 2 Artifact，但不会创建 Release。
3. 推送与 `version.env` 一致且位于 `main` 的 `v*` tag，会创建包含 ZIP 和 checksum 的 Pre-release。
4. Release 公开前不存在用户可见的半成品状态。
5. 重跑失败的 tag workflow 不会覆盖已经公开的 Release。
6. 本地开发启动与 CI 发布共享应用组装逻辑。
7. 未来启用 Developer ID 时不需要重写构建和 Release 编排。
