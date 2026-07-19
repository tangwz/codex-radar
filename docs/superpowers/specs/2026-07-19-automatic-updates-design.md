# 自动更新设计

## 背景

CodexRadar 当前是 macOS 14+ 的 SwiftPM 菜单栏应用，通过 `script/build_and_run.sh` 组装并 ad-hoc 签名应用。仓库已有 `2026-07-18-github-release-automation-design.md`，定义了 Universal 2 构建、GitHub Pre-release、版本管理、签名和验证边界，但明确将 Sparkle 与 appcast 排除在首期范围外。

本设计是上述发布设计的后续扩展。它不改变既有发布设计对构建、版本和未公证分发的约束，而是在其产物与 GitHub Release 之上增加安全的应用内更新链路。两个设计中若出现范围描述差异，以本设计对 Sparkle、appcast 和更新发布阶段的约束为准。

当前无法使用 Apple Developer Program，因此首期继续采用 ad-hoc 应用签名。该选择不能提供 Apple Developer ID 身份或消除首次安装时的 Gatekeeper 限制，但不会阻塞首装后的 Sparkle Ed25519 更新验证。

## 目标

- 第一个包含 Sparkle 的 bootstrap 版本由用户手动安装一次，后续版本可在应用内完成检查、下载和安装。
- 默认自动检查并后台下载更新；更新准备完成后由 Sparkle 提示重启安装。
- About 页面提供自动更新开关、当前版本和“检查更新…”按钮。
- 首期只提供一个 Stable 更新流，不展示频道选择。
- 使用 Sparkle Ed25519 archive signature、signed feed 和解压前验证保护更新链路。
- 使用 GitHub Immutable Releases 和版本固定的资产 URL 保证已发布资产不可变。
- 更新失败时保留当前可运行应用，禁止降级到未验签内容或自研高权限替换流程。
- 为未来切换 Developer ID 签名和公证保留稳定边界。

## 非目标

- Beta、nightly 或其他更新频道。
- Delta update。
- Developer ID、公证或 Mac App Store 分发。
- Homebrew Cask 更新协调。
- 自研安装器、提权 helper 或 shell 替换应用。
- 开发构建连接生产 feed。
- 匿名系统信息上报。

## 方案选择

采用 Sparkle 2、GitHub Releases 和仓库根目录 `appcast.xml`：

- Sparkle 负责更新检查、下载、验签、原子替换、恢复和标准用户界面。
- GitHub Release 承载版本固定且不可变的 ZIP、checksum 和候选 appcast。
- `https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml` 是生产 feed。
- Release workflow 在候选资产公开、复验和端到端测试通过后，使用 GitHub Contents API compare-and-swap 更新生产 feed。

不采用 GitHub Pages，因为当前只有一个 Stable feed，额外部署边界没有足够收益。不自研更新器，因为原子替换、权限、App Translocation、恢复和签名验证的安全成本明显高于引入成熟框架。

## 产品行为

### 自动更新

- 正式发布包首次启动时默认开启 automatic check 和 automatic download。
- Sparkle 的 Info.plist 默认值决定首次状态；运行时 API 只响应用户修改，不反复覆盖用户选择。
- 用户选择保存在 UserDefaults 中，重新打开应用或 About 页面时保持不变。
- 检查调度使用 Sparkle 默认策略，不增加 CodexRadar 自有轮询 timer。
- 更新下载完成后使用 Sparkle 标准流程提示重启安装；用户暂不重启时允许在退出应用时安装。

### 手动检查

- About 页面始终为可更新的正式包提供“检查更新…”按钮。
- 手动操作走 Sparkle user-driven check 路径，必须向用户显示无更新、可用更新或可操作错误。
- 后台检查失败保持静默，避免菜单栏应用产生干扰性窗口。

### 更新频道

- 首期生产 appcast 只保留最新的一个完整更新 entry，不保留历史 entry、不生成 delta，也不写入 `sparkle:channel`。任意旧版本均直接更新到当前最新完整 ZIP。
- About 页面不展示频道 picker。
- 未来增加频道时通过 updater delegate 的 allowed channels 扩展，不改变当前 feed URL 或 updater 接口。

## 应用架构

### `UpdaterProviding`

应用内定义主线程隔离的 updater 协议，暴露：

- updater 是否可用及不可用原因；
- automatic check 状态；
- automatic download 状态；
- user-driven check 操作。

About 页面只依赖该协议，不导入 Sparkle。测试使用 fake updater 验证绑定和操作次数。

### `SparkleUpdaterController`

- 封装 `SPUStandardUpdaterController`。
- 由 `AppDelegate` 创建并持有，生命周期与应用一致。
- 启动时读取 Sparkle 已持久化的设置，不维护第二套相互竞争的状态源。
- 自动更新开关同时修改 automatic check 和 automatic download。
- 手动检查调用 Sparkle 的 user-driven API。
- 通过 updater delegate 记录安全验证失败和安装失败诊断，但不记录 feed 内容、私钥或其他敏感数据。

### `DisabledUpdaterController`

以下场景使用 no-op 实现，不创建 Sparkle updater，也不访问生产 feed：

- `swift run`；
- 单元测试；
- 普通本地开发包；
- 缺少显式更新启用标记的应用包。

是否启用更新由最终应用 Info.plist 中的 CodexRadar 自有布尔标记决定，不通过 ad-hoc 签名状态推断，因为开发包和发布包都会使用 ad-hoc 签名。

### About 页面

About Form 在 hero 与链接之间增加“更新”Section：

- 自动检查更新 Toggle；
- 当前版本和“检查更新…”按钮；
- updater 不可用时显示不可用原因，不渲染可交互假控件。

新增内容提供 English、简体中文和 VoiceOver label。Stable-only 模式不显示频道行。

## Sparkle 配置

正式发布包最终 Info.plist 必须包含并验证：

- `SUFeedURL`：生产 raw appcast URL；
- `SUPublicEDKey`：CodexRadar 独立 Ed25519 公钥；
- `SUEnableAutomaticChecks = true`；
- `SUAutomaticallyUpdate = true`；
- `SUVerifyUpdateBeforeExtraction = true`；
- `SURequireSignedFeed = true`；
- CodexRadar 自有更新启用标记为 `true`。

普通开发包将自有更新启用标记设为 `false`。测试不得只检查源模板，必须从解压后的最终应用读取这些值。

SwiftPM 依赖精确锁定到 Sparkle `2.9.3` 并提交 `Package.resolved`。升级 Sparkle 是独立、可审阅的依赖变更，需要重新执行打包、签名和端到端更新矩阵。

## 打包与 ad-hoc 签名

### Framework 嵌入

- 将 SwiftPM 构建产物中的 `Sparkle.framework` 复制到 `Contents/Frameworks`，保留符号链接和执行权限。
- 主程序包含 `@executable_path/../Frameworks` rpath。
- 打包器校验 framework 真实路径、`Versions/Current` 和内部目标均未逃逸 framework 根目录。

### 签名顺序

发布脚本不得把 `codesign --deep` 当作正确签名顺序的替代。它需要解析当前 Sparkle framework 布局并由内到外 ad-hoc 签名：

1. XPC services 和内部 executables；
2. `Autoupdate`；
3. `Updater.app`；
4. `Sparkle.framework`；
5. CodexRadar 主程序及未来其他嵌套代码；
6. `CodexRadar.app`。

路径缺失、重复、符号链接逃逸或 framework 布局无法唯一解析时立即失败。签名后执行严格 codesign 验证，并在压缩、解压后再次验证。

### ZIP 结构

- 使用保留符号链接和执行权限的系统归档工具。
- ZIP 顶层只允许一个 `CodexRadar.app`。
- 顶层不允许脚本、额外可执行文件、AppleDouble 或其他隐藏负载。
- bundle 内符号链接必须解析到 bundle 内部合法目标。

## 信任模型

当前没有 Developer ID。对于已经安装、且未被本机管理员权限篡改的应用，固化在最终应用 Info.plist 中的 `SUPublicEDKey` 是更新信任锚；对应的 Ed25519 私钥是唯一更新签名凭据。

首次手动安装包及其分发渠道是独立的 bootstrap trust boundary。用户在第一次安装时尚不能依赖应用内公钥证明下载来源，因此首装页面需要提供：

- 版本固定的 GitHub Release URL；
- 发布的 SHA-256；
- 未经 Developer ID 签名和 Apple 公证的明确说明。

更新供应链的其他信任边界包括：

- GitHub 仓库及其管理员；
- workflow 和 CODEOWNERS 审批；
- `release` Environment 审批者；
- 实际运行签名步骤的 GitHub-hosted runner；
- 固定版本的 Sparkle 工具和 GitHub Actions。

本机管理员或 root 已经控制用户电脑时不属于更新机制可抵御的威胁。

## Ed25519 密钥管理

- 使用 Sparkle `generate_keys` 一次性生成 CodexRadar 独立密钥，不复用其他应用的密钥。
- 公钥进入最终应用 Info.plist。
- 私钥存入受保护的 GitHub `release` Environment Secret，并保留至少一份离线加密备份。
- 私钥不进入命令行参数、工作目录、临时文件、缓存或 Artifact。
- 签名步骤仅通过标准输入和 Sparkle `--ed-key-file -` 读取私钥。
- 不使用已弃用的 `-s` 私钥参数。
- 日志禁止输出 secret、shell tracing 或包含 secret 的派生命令。

没有 Developer ID 时，私钥丢失后无法通过现有安装安全轮换 Ed25519 key。恢复方式只能是使用新 key 重新发布并要求用户手动安装，因此离线备份是发布前硬性条件。

## GitHub Actions 安全边界

### Job 分离

`build-test-package` job：

- `contents: read`；
- 无权访问 `release` Environment 和 Ed25519 私钥；
- 执行测试、构建、打包、最终应用验证和 Artifact 上传。

`sign-and-publish` job：

- 绑定 `release` Environment；
- 具有最小 `contents: write`；
- 在私钥注入前下载 Artifact、验证 checksum、复验 ZIP 和预置 Sparkle 工具；
- 私钥注入后只执行固定的 Sparkle 签名工具、GitHub CLI/API 发布操作和最小 shell glue；
- 私钥注入后不执行项目脚本、构建命令或第三方 Action。

`activate-production-feed` job：

- 依赖公开资产复验和受控真实 Mac 资格测试；
- 绑定不保存签名私钥的 `production-feed` Environment，并等待最终人工审批；
- 具有更新 `main/appcast.xml` 所需的最小 `contents: write`；
- 重新读取生产 appcast blob SHA，执行 compare-and-swap，随后复验 raw feed；
- 无权访问 Ed25519 私钥，也不重新生成或修改候选 signed appcast。

### Repository 配置

- `release` Environment 只允许 `v*` tag 部署。
- `production-feed` Environment 同样只允许对应 `v*` tag，且不保存签名私钥。
- 套餐支持时，两个 Environment 均启用 required reviewer 并关闭发起者自我审批；`release` 审批发生在私钥暴露前，`production-feed` 审批发生在真实 Mac 资格测试后。
- `.github/workflows/**` 由 CODEOWNERS 保护。
- main 分支规则要求 review 和 CI；只为受保护的 release actor 提供生产 appcast compare-and-swap 所需的最小 bypass。
- 所有 Action，包括 GitHub 官方 Action，固定完整 commit SHA。
- release workflow 使用按 tag/repository 唯一的 concurrency group，但 concurrency 不替代 blob SHA 校验。

## Signed feed 与 release notes

- 开启 `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction`。
- `generate_appcast` 负责 archive signature、feed signature 和 release notes signature，不手写 Ed25519 签名。
- Release notes 优先嵌入 signed appcast；若使用外链，只允许版本固定、同样签名且不可变的文件。
- appcast 和外链 release notes 在最终签名后不得编辑；任何字节变化都需要重新生成并签名。
- 生产 appcast 仅引用包含固定 tag 和固定资产名的 URL，禁止 `latest/download/...` 或其他移动地址。

## Immutable Release 发布协议

仓库必须在首个自动更新版本发布前启用 GitHub Immutable Releases。发布后的 tag 和 assets 由平台锁定；workflow 不依赖“不要覆盖”的人为约定。

固定发布顺序如下：

1. 从 tag 构建最终 Universal 2 ZIP。
2. 检查最终 ZIP 和内部应用。
3. 通过 stdin 生成并验证 Ed25519 archive signature 和候选 signed appcast。
4. 创建 Draft Release，上传 ZIP、checksum 和候选 appcast。
5. 通过认证的 Draft asset 下载路径重新下载，确认字节、长度和 SHA-256 与本地产物一致。
6. 发布 GitHub Immutable Pre-release。
7. 通过公开的版本固定 URL 重新下载 ZIP 和候选 appcast，验证 release attestation、长度、SHA-256 和 Ed25519 签名。
8. 使用候选 appcast 执行发布资格端到端测试。
9. `activate-production-feed` 等待 `production-feed` Environment 最终审批；审批记录确认受控真实 Mac 资格测试通过。
10. 读取生产 `appcast.xml` 当前 blob SHA，以 compare-and-swap 写入候选 appcast 的精确字节。
11. 重新获取 raw feed，验证 feed signature、版本、enclosure URL 和资产签名。
12. raw feed 生效后才将发布标记为完整并对外宣布。

如果公开后的 Immutable Release 未通过第 7 或第 8 步，它保持公开但永不写入生产 feed。修复必须递增 build number 并创建新 Release，不能删除、替换或复用失败版本的资产。

## 版本与并发规则

- `MARKETING_VERSION` 继续使用 `MAJOR.MINOR.PATCH`。
- `BUILD_NUMBER` 使用单调递增正整数。
- 最终 Info.plist 的 `CFBundleVersion`、版本配置和 appcast 的 `sparkle:version` 必须完全一致。
- 新 build 必须严格高于生产 appcast 中最高 build。
- feed 中不得出现重复 build 或同一 build 指向不同资产。
- GitHub Contents API 更新现有 appcast 时必须提交当前 blob SHA。
- HTTP 409、422 或任何 SHA 冲突都终止发布；workflow 重新读取最新 feed 后由安全重跑继续，不执行强制覆盖。

## 客户端失败处理

### 可恢复故障

网络不可用、DNS 问题、超时和临时服务器错误视为可恢复故障：

- 保留当前应用；
- 后台检查不弹窗；
- 按 Sparkle 正常周期重试，不增加高频重试循环；
- 用户手动检查时显示可理解的错误。

### 安全验证失败

feed signature、release notes signature、archive signature、长度或内容验证失败视为安全故障：

- 硬失败并丢弃候选下载；
- 保留当前应用；
- 记录高优先级诊断信息，但不记录敏感 feed 内容；
- 不降级使用未签名 feed、未验签 ZIP 或 checksum-only 信任；
- 允许下一正常周期重新检查，但不高频重试。

### 只读位置与 App Translocation

- 不运行 `sudo`、`rm`、`cp` 或其他高权限 shell 命令。
- 后台检查只记录失败，不产生干扰性窗口。
- 用户主动检查使用 Sparkle user-driven API，必须显示可操作提示：退出应用，将应用移动到 `/Applications` 或 `~/Applications`，重新启动后再检查。
- 发布资格测试验证当前 Sparkle 标准 user driver 的实际行为；如果无法稳定满足提示要求，updater adapter 提供只针对已识别安装位置错误的 fallback alert。
- 不假设 Sparkle 默认 UI 一定会为只读卷或 App Translocation 显示错误。

### 安装失败

- 应用替换、权限处理、原子操作和恢复完全交给 Sparkle。
- CodexRadar 不实现自有 `rm/cp` 安装路径。
- 安装失败时保留或恢复原应用；无法证明原应用可继续运行时发布资格测试失败。

## 验证门禁

### 最终应用与 ZIP

- ZIP 顶层只包含一个预期名称的应用。
- 归档保留执行权限和合法符号链接。
- 最终 Info.plist 的 bundle ID、marketing version、build、feed URL、公钥和全部更新安全配置正确。
- 主程序、Sparkle framework、XPC services、helpers 和其他所有 Mach-O 均被递归枚举。
- 需要随发布支持的每个 Mach-O 同时包含 `arm64` 和 `x86_64`。
- framework 内部签名和外层应用签名通过严格验证。
- 解压后的应用与压缩前应用满足相同检查。

### Feed 与 Release

- `sparkle:version` 与最终 `CFBundleVersion` 相同且严格递增。
- enclosure 使用版本固定 URL，长度和 Ed25519 signature 正确。
- signed feed 和 release notes 在签名后没有字节变化。
- 公开 Release 显示 Immutable 并通过 release integrity 验证。
- 从公开资产重新下载的 ZIP 与 CI 生成物 SHA-256 相同，并再次通过 Sparkle 验签。

### 端到端更新

公开 Immutable Release 后、更新生产 feed 前执行：

1. 使用真实上一公开版本的 production-equivalent 副本；只把 feed 指向 Immutable Release 中版本固定的候选 signed appcast，不修改 updater 代码或公钥。
2. 验证发现更新、后台下载、重启安装、版本升级和用户设置保留。
3. 覆盖断网、损坏 feed、错误 feed signature、截断 ZIP 和错误 archive signature。
4. 确认每个失败场景保留可运行旧应用，且没有未验签降级。
5. 在受控真实 Mac 上分别验证只读卷和 App Translocation。

App Translocation 不能被视为 GitHub-hosted runner 上可稳定复现的普通自动化测试。每次发布需要在受控真实 Mac 完成资格检查，并由 `production-feed` Environment 的最终审批记录确认。任何 Sparkle 版本、打包布局或更新交互变更都必须重新执行完整矩阵。

## 测试策略

### Swift 测试

- fake updater 驱动的 About 页面状态和操作测试。
- automatic check 与 automatic download 同步测试。
- 用户关闭自动更新后的持久化测试。
- user-driven check 单次调用测试。
- disabled updater 在开发和测试环境不访问 feed 的测试。
- English、简体中文和 accessibility label 覆盖。

### 脚本测试

- Sparkle framework 布局和安全路径解析 fixtures。
- nested signing targets 和由内到外顺序测试。
- ZIP 顶层、权限、符号链接逃逸和隐藏负载 fixtures。
- 最终 Info.plist 配置检查。
- Mach-O 递归枚举和缺失架构失败测试。
- 版本倒退、重复 build 和 appcast 不一致测试。
- 移动 enclosure URL、缺失资产、错误长度和缺失签名测试。
- signed feed 或 release notes 被修改后的失败测试。
- Contents API blob SHA 冲突测试。

### Workflow 测试

- workflow 通过 `actionlint`。
- shell 脚本通过语法和静态检查。
- 手动 dry run 产出完整 Artifact，但不创建 Release、不读取发布私钥。
- secret 只在 `sign-and-publish` 的单一签名步骤引用。
- `activate-production-feed` 不可访问私钥，必须经过独立 Environment 审批后才能写入生产 appcast。
- job 级 permissions、Environment、concurrency 和完整 Action SHA 由静态检查断言。

## 验收标准

1. 第一个 Sparkle bootstrap 版本手动安装后可以在应用内完成后续升级。
2. 自动检查和下载默认开启，用户可关闭并可随时手动检查。
3. Stable-only 模式下不存在频道 UI 或 beta feed entry。
4. 开发包、测试包和 `swift run` 不创建 updater 或访问生产 feed。
5. 所有发布可执行代码和更新内容通过规定的结构、架构、签名和解压后验证。
6. 私钥不落盘、不进入命令参数，仅暴露给隔离的签名步骤，并存在离线加密备份。
7. 任一构建、签名、上传、公开复验或端到端测试失败时，生产 appcast 保持不变。
8. 生产 feed 只引用版本固定、公开且 Immutable 的资产。
9. 客户端在网络和安全验证失败时保留当前应用，不执行未验签降级。
10. 用户主动检查时能获得只读位置和 App Translocation 的可操作错误。
11. 未来切换 Developer ID 不改变 bundle ID、feed URL、Ed25519 key 或应用侧 updater 接口。

## Developer ID 升级路径

未来取得 Apple Developer Program 资格后：

- 保持 `com.terence.codex-radar` bundle ID；
- 保持现有 `SUPublicEDKey` 和私钥；
- 保持生产 appcast URL；
- 将应用及 Sparkle nested code 从 ad-hoc 切换为 Developer ID 由内到外签名；
- 启用 hardened runtime、公证、staple 和 Gatekeeper 验证；
- 通过现有 Ed25519 信任链发布首次 Developer ID signed update；
- 完成真实 ad-hoc bootstrap 版本到 Developer ID 版本的端到端升级测试后，再将 GitHub Release 从 Pre-release 改为正式 Release。

该升级只改变发布签名和公证边界，不重写 About UI、`UpdaterProviding`、Sparkle controller 或 feed 协议。

## 参考资料

- [Sparkle Documentation](https://sparkle-project.org/documentation/)
- [Sparkle Customization](https://sparkle-project.org/documentation/customization/)
- [Sparkle Sandboxing](https://sparkle-project.org/documentation/sandboxing/)
- [Sparkle generate_appcast source](https://github.com/sparkle-project/Sparkle/blob/2.x/generate_appcast/main.swift)
- [CodexBar Sparkle integration](https://github.com/steipete/CodexBar/blob/main/docs/sparkle.md)
- [GitHub Immutable Releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub release immutability settings](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
- [GitHub Contents API](https://docs.github.com/en/rest/repos/contents)
- [GitHub Actions secure use reference](https://docs.github.com/en/enterprise-cloud@latest/actions/reference/security/secure-use)
