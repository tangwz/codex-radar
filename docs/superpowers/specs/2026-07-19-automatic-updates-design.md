# 自动更新设计

## 背景

CodexRadar 当前是 macOS 14+ 的 SwiftPM 菜单栏应用，通过 `script/build_and_run.sh` 组装并 ad-hoc 签名应用。仓库已有 `2026-07-18-github-release-automation-design.md`，定义了 Universal 2 构建、GitHub Pre-release、版本管理、签名和验证边界，但明确将 Sparkle 与 appcast 排除在首期范围外。

本设计是上述发布设计的后续扩展。它不改变既有发布设计对构建、版本和未公证分发的约束，而是在其产物与 GitHub Release 之上增加安全的应用内更新链路。两个设计中若出现范围描述差异，以本设计对 Sparkle、appcast 和更新发布阶段的约束为准。

当前无法使用 Apple Developer Program，因此首期继续采用 ad-hoc 应用签名。该选择不能提供 Apple Developer ID 身份或消除首次安装时的 Gatekeeper 限制，但不会阻塞首装后的 Sparkle Ed25519 更新验证。

## 目标

- 第一个包含 Sparkle 的 bootstrap 版本由用户手动安装一次，后续版本可在应用内完成检查、下载和安装。
- 默认自动检查并后台下载更新；更新准备完成后由 Sparkle 提示重启安装。
- About 页面提供自动更新开关、当前版本和“检查更新…”按钮。
- 首期只提供一个 Production Update 流，不展示频道选择。
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
- Candidate Release 是承载 ZIP、checksum 和候选 appcast 的 GitHub Draft Release，对普通用户不可见。
- `https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml` 是生产 feed。
- 生产 feed URL 固化进已安装应用，构成长期兼容性契约；仓库 owner、名称、默认分支或文件路径发生变化时，旧 URL 必须继续提供有效的 signed migration feed。
- Release workflows 在 Draft 资产复验和端到端测试通过后公开 Immutable Pre-release；公开资产复验成功后，使用 GitHub Contents API compare-and-swap 更新生产 feed。

不采用 GitHub Pages，因为当前只有一个 Production Update feed，额外部署边界没有足够收益。不自研更新器，因为原子替换、权限、App Translocation、恢复和签名验证的安全成本明显高于引入成熟框架。

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
- 单 entry 策略以最低系统版本保持 macOS 14 为前提。不得在不迁移 feed 策略的情况下提高最低系统版本；提高前必须至少保留每个仍需迁移的系统版本对应的最后兼容 entry。
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

新增内容提供 English、简体中文和 VoiceOver label。单一 Production Update 流不显示频道行。

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

SwiftPM 依赖精确锁定到 Sparkle `2.9.4` 并提交 `Package.resolved`。该版本包含与菜单栏、无 Dock 应用相关的标准更新 UI 激活修复。升级 Sparkle 是独立、可审阅的依赖变更，需要重新执行打包、签名和端到端更新矩阵。

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

首装以固定 GitHub Release 页面及仓库治理作为引导信任来源。同页 SHA-256 只用于发现传输损坏，不得表述为开发者身份认证，也不能抵御 GitHub 账号或仓库被攻破。安装文档只提供针对单个 CodexRadar 应用的 macOS 打开方式，不要求用户全局关闭 Gatekeeper；首装完成后，后续更新才由应用内固化的 Ed25519 公钥保护。

更新供应链的其他信任边界包括：

- GitHub 仓库及其管理员；
- workflow 和 CODEOWNERS 审批；
- Release Operator；
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

没有 Developer ID 时，私钥丢失、完整性无法确认或疑似泄露都永久终止当前 Update Trust Chain。维护者必须立即停止自动更新发布和生产 feed 推进，保留现有公开 Release 供审计并发布安全公告；恢复方式只能是生成新 key、重新发布 bootstrap 版本并要求用户手动安装。不得使用旧 key 制作自动换钥更新，也不得降级到无签名更新，因此离线备份是发布前硬性条件。

## GitHub Actions 安全边界

### Job 分离

`build-test-package` job：

- `contents: read`；
- 无权访问 `release` Environment 和 Ed25519 私钥；
- 执行测试、构建、打包、最终应用验证和 Artifact 上传。

`prepare-candidate` workflow 中的 `sign-candidate` job：

- 绑定 `release` Environment；
- 具有最小 `contents: write`；
- 在私钥注入前下载 Artifact、验证 checksum、复验 ZIP 和预置 Sparkle 工具；
- 私钥注入后只执行固定的 Sparkle 签名工具、GitHub CLI/API 发布操作和最小 shell glue；
- 私钥注入后不执行项目脚本、构建命令或第三方 Action。

`publish-update` workflow：

- 仅允许 `workflow_dispatch` 手动触发，并要求选择一个仍为 Draft 的 `v*` tag；触发动作表示 Release Operator 已在受控真实 Mac 上完成该 Candidate Release 的资格测试；
- 重新下载 Draft assets，复验 tag、版本、候选 appcast、长度、SHA-256 和 Ed25519 签名，且不信任跨 workflow 的可变 Artifact；
- 无权访问 Ed25519 私钥，不重新生成、修改或重新签名任何资产；
- 校验通过后公开 Immutable Pre-release，并从公开版本固定 URL 再次复验。

`publish-update` workflow 中的 `activate-production-feed` job：

- 依赖同一 workflow 中的公开资产复验；
- 具有更新 `main/appcast.xml` 所需的最小 `contents: write`；
- 重新读取生产 appcast blob SHA，执行 compare-and-swap，随后复验 raw feed；
- 无权访问 Ed25519 私钥，也不重新生成或修改候选 signed appcast。

### Repository 配置

- `release` Environment 只允许 `v*` tag 部署。
- 当前采用 Single-Operator Release：`release` Environment 在私钥暴露前要求人工审批，并允许同一 Release Operator 审批自己发起的部署。
- `prepare-candidate` 完成 Draft 后结束，不等待本机测试；`publish-update` 的手动触发记录 Release Operator 对真实 Mac 资格测试结果的确认。
- 生产 feed 在 Draft 资格测试和公开资产复验成功后自动激活，不设置第二个人工审批。
- 当前剩余风险是单一 GitHub 管理员账号失陷后仍可控制仓库、审批和发布链路。增加第二位可信 Release Operator 后，必须启用 required reviewer 并禁止发起者自我审批。
- `.github/workflows/**` 由 CODEOWNERS 保护。
- main 分支规则要求 review 和 CI；只为受保护的 release actor 提供生产 appcast compare-and-swap 所需的最小 bypass。
- 所有 Action，包括 GitHub 官方 Action，固定完整 commit SHA。
- 两个 workflow 使用相同的按 tag/repository 唯一 concurrency group，但 concurrency 不替代 Draft 状态、资产摘要或 blob SHA 校验。

## Signed feed 与 release notes

- 开启 `SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction`。
- `generate_appcast` 负责 archive signature、feed signature 和 release notes signature，不手写 Ed25519 签名。
- Release notes 优先嵌入 signed appcast；若使用外链，只允许版本固定、同样签名且不可变的文件。
- appcast 和外链 release notes 在最终签名后不得编辑；任何字节变化都需要重新生成并签名。
- 生产 appcast 仅引用包含固定 tag 和固定资产名的 URL，禁止 `latest/download/...` 或其他移动地址。
- 发布验证必须断言最终应用中的 `SUFeedURL` 与兼容性契约完全一致；禁止因仓库重命名或迁移直接修改或删除旧 URL 上的 feed。

## Immutable Release 发布协议

仓库必须在首个自动更新版本发布前启用 GitHub Immutable Releases。发布后的 tag 和 assets 由平台锁定；workflow 不依赖“不要覆盖”的人为约定。

固定发布顺序如下：

`prepare-candidate` workflow：

1. 从 tag 构建最终 Universal 2 ZIP。
2. 检查最终 ZIP 和内部应用。
3. 通过 stdin 生成并验证 Ed25519 archive signature、生产候选 signed appcast，以及只用于受控测试的 signed qualification feed。qualification feed 使用相对 enclosure URL，使签名后的 feed 能从本机随机端口解析到同目录 ZIP，不需要改写任何已签名字节。
4. 创建 Candidate Release，上传 ZIP、checksum 和生产候选 appcast。
5. 通过认证的 Draft asset 下载路径重新下载，确认字节、长度和 SHA-256 与本地产物一致。
6. 生成 qualification bundle：包含第 5 步重新下载的精确 ZIP、signed qualification feed、manifest 和固定 Sparkle `2.9.4` CLI；该 bundle 不含私钥，并作为短期 Actions Artifact 提供给 Release Operator。
7. workflow 结束，Candidate Release 保持为不可见 Draft。

本地资格测试：

8. Release Operator 在受控真实 Mac 上下载 qualification bundle；统一脚本先验证 manifest 和工具版本，再仅绑定 `127.0.0.1` 的随机端口启动临时 HTTP 服务。
9. 脚本使用固定版本的官方 `sparkle bundle --feed-url`，以本机 feed URL 驱动真实上一 Production Update 的应用副本完成端到端更新。测试不修改 CodexRadar bundle、updater 代码、公钥或 ATS 配置；本机 HTTP 只承载已签名 feed 和已签名 archive。

`publish-update` workflow：

10. 资格测试通过后，Release Operator 手动触发 workflow 并选择对应 tag；手动触发记录即为资格测试通过的发布声明。
11. workflow 重新下载并独立复验 Draft assets，随后发布 GitHub Immutable Pre-release；`Pre-release` 只表达未经过 Apple 公证的分发属性。
12. 通过公开的版本固定 URL 重新下载 ZIP 和生产候选 appcast，验证 release attestation、长度、SHA-256 和 Ed25519 签名。
13. 公开复验成功后，`activate-production-feed` 读取生产 `appcast.xml` 当前 blob SHA，以 compare-and-swap 写入生产候选 appcast 的精确字节。
14. 重新获取 raw feed，验证 feed signature、版本、enclosure URL 和资产签名。
15. raw feed 生效后，该版本成为 Production Update，并可对外宣布自动更新已发布。

`v*` tag 一经推送即永久保留。Candidate Release 资格失败时，Release Operator 运行受控清理命令，只删除不可见的 Draft Release；公开后的 Immutable Pre-release 若未通过第 12 步，workflow 只删除该 Release。两种失败都会永久作废对应 App Version、build number 和 tag，修复必须同时提高版本和 build number，并使用匹配的新 tag；任何阶段都不得用相同版本标识重新构建或重试。Release 自动删除或公开复验失败时停止 workflow 并要求 Release Operator 介入，不激活 Production Feed。

第 13 步 CAS 成功后若第 14 步因 raw 缓存或临时网络故障超时，发布进入 Activation Pending：不回滚 feed、不删除 Release，也不宣布完成。安全重跑只能确认仓库 blob 仍是同一候选 appcast 并继续复验 raw URL，不得重新生成或改写 appcast。raw URL 返回候选精确字节后才完成发布；若返回既不是 CAS 前旧 feed 也不是候选 feed 的内容，立即停止并要求 Release Operator 调查。

本协议在自动更新启用后取代早期 GitHub Release 设计中的 Draft 复用规则；已经公开并成功进入 Production Feed 的 Release 仍然不可删除、替换或复用。

## 版本与并发规则

- `MARKETING_VERSION` 继续使用 `MAJOR.MINOR.PATCH`。
- `BUILD_NUMBER` 使用单调递增正整数。
- 最终 Info.plist 的 `CFBundleVersion`、版本配置和 appcast 的 `sparkle:version` 必须完全一致。
- 新 build 必须严格高于生产 appcast 中最高 build。
- feed 中不得出现重复 build 或同一 build 指向不同资产。
- 一旦语法合法的 `vX.Y.Z` tag 触发发布，App Version、build number 和 tag 即被该次构建占用；workflow 只允许该 tag push 的第一次 attempt 进入签名路径。无论失败发生在 Draft 创建前、Draft 资格测试还是公开复验阶段，都必须永久作废这组三个标识并保留原 tag。下一次尝试必须同时提高版本和 build number，并创建匹配的新 tag；README 的版本固定安装链接保持指向最后一个成功公开的 Release，直到新 Candidate 成功激活后再单独推进。每个 bootstrap 或普通 Candidate 都在签名前与全部其他合法 `vX.Y.Z` tag identity 比较。malformed `v*` tag 由自身 workflow 拒绝，但不进入 release identity history。校验成功是该 Candidate 的 identity reservation point，后续 tag 不追溯性地使它失效，而是在自己的签名前门禁中继续严格递增。两个发布 workflow 使用带 `queue: max` 的仓库级 concurrency 串行执行并保留 pending run；bootstrap 资格另外要求 feed 不存在且 Release 历史为空，而不是固定版本号。
- 生产 appcast 仍为单 entry 时，候选应用的最低系统版本必须与当前 Production Update 一致；任何提高都直接终止发布，直到多 entry 兼容策略另行设计并落地。
- GitHub Contents API 更新现有 appcast 时必须提交当前 blob SHA。
- HTTP 409、422 或任何 SHA 冲突都终止发布；workflow 重新读取最新 feed 后由安全重跑继续，不执行强制覆盖。
- CAS 成功后的 Activation Pending 重跑只允许对同一候选 appcast 执行只读复验；不得以“恢复旧状态”为由执行第二次 feed 写入。

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

## 已激活版本的停止分发

Production Update 在激活后发现严重功能回归时，Release Operator 可以执行 Distribution Halt：

- 读取当前生产 appcast blob SHA，并以 compare-and-swap 恢复上一份已验证 signed appcast 的精确字节；
- 复验仓库 blob 和 raw URL，未确认前不宣布停止分发完成；
- 保留问题版本的 Immutable Release、tag 和资产，不删除或替换历史；
- 明确说明该操作只阻止尚未升级的客户端继续发现问题版本，不会降级已经安装该版本的客户端；
- 修复使用更高 App Version 和 build number 发布，不复用问题版本标识。

Distribution Halt 只处理功能回归。若事件涉及 Ed25519 私钥丢失、完整性无法确认或疑似泄露，则终止 Update Trust Chain，不恢复或继续推进现有 feed，并按手动 bootstrap 流程处理。

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
- 首装文档把 SHA-256 描述为完整性校验，明确未签名和未公证状态，且不包含全局关闭 Gatekeeper 的命令。

### 端到端更新

Candidate Release 公开前执行：

1. 使用真实上一 Production Update 的副本和固定版本官方 Sparkle CLI；CLI 通过 `--feed-url` 指向本地 signed qualification feed，不修改 CodexRadar bundle、updater 代码、公钥或 ATS 配置。
2. 验证发现更新、后台下载、重启安装、版本升级和用户设置保留。
3. 确认安装后的 App Version 与 Candidate Release 一致，既有用户设置未丢失，旧应用未残留为半安装状态。

每个 Candidate Release 只要求上述单次成功路径。首个 Sparkle bootstrap 版本，以及 Sparkle 版本、updater 代码、签名配置或打包布局发生变化时，必须额外执行完整故障矩阵：断网、损坏 feed、错误 feed signature、截断 ZIP、错误 archive signature、只读卷和 App Translocation，并确认每个场景都保留可运行旧应用且没有未验签降级。

App Translocation 不能被视为 GitHub-hosted runner 上可稳定复现的普通自动化测试。需要完整矩阵时，必须在受控真实 Mac 上执行；`publish-update` 的手动触发记录 Release Operator 对当次所需资格范围的通过声明，并作为发布 Immutable Pre-release 的硬依赖。

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
- 固化 `SUFeedURL` 与 Production Feed 兼容性契约的回归测试。
- qualification feed 使用相对 enclosure URL，qualification server 只绑定 loopback，并在成功、失败和取消路径尽力清理。
- qualification bundle 的 manifest、精确 Draft ZIP 和固定 Sparkle CLI 版本校验。
- Mach-O 递归枚举和缺失架构失败测试。
- 版本倒退、重复 build 和 appcast 不一致测试。
- 单 entry feed 下最低系统版本提高时的拒绝测试。
- 移动 enclosure URL、缺失资产、错误长度和缺失签名测试。
- signed feed 或 release notes 被修改后的失败测试。
- CI 集成测试始终覆盖损坏 feed、错误 feed signature、截断 ZIP 和错误 archive signature；这些自动化检查不替代触发条件满足时的真实 Mac 完整矩阵。
- Contents API blob SHA 冲突测试。
- CAS 成功后 raw feed 暂时返回旧字节、候选字节和未知字节三种状态的 Activation Pending 测试。
- Distribution Halt 的 blob SHA 冲突、上一份 feed 签名验证和 raw URL 复验测试。

### Workflow 测试

- workflow 通过 `actionlint`。
- shell 脚本通过语法和静态检查。
- 手动 dry run 产出完整 Artifact，但不创建 Release、不读取发布私钥。
- secret 只在 `prepare-candidate` 的单一 `sign-candidate` 步骤引用。
- `publish-update` 只能手动选择仍为 Draft 的 tag，且必须独立复验 Draft assets；整个 workflow 不可访问私钥。
- `activate-production-feed` 只能在同一 `publish-update` workflow 的公开资产复验成功后写入生产 appcast。
- 两个 workflow 的 job 级 permissions、Environment、共享 concurrency 和完整 Action SHA 由静态检查断言。

## 验收标准

1. 第一个 Sparkle bootstrap 版本手动安装后可以在应用内完成后续升级。
2. 自动检查和下载默认开启，用户可关闭并可随时手动检查。
3. 单一 Production Update 流下不存在频道 UI 或 beta feed entry。
4. 开发包、测试包和 `swift run` 不创建 updater 或访问生产 feed。
5. 所有发布可执行代码和更新内容通过规定的结构、架构、签名和解压后验证。
6. 私钥不落盘、不进入命令参数，仅暴露给隔离的签名步骤，并存在离线加密备份。
7. CAS 之前任一构建、签名、上传、公开复验或所需资格测试失败时，生产 appcast 保持不变；CAS 成功后的 raw 复验超时进入 Activation Pending，不执行回滚写入。
8. 生产 feed 只引用版本固定、公开且 Immutable 的资产。
9. 客户端在网络和安全验证失败时保留当前应用，不执行未验签降级。
10. 用户主动检查时能获得只读位置和 App Translocation 的可操作错误。
11. 未来切换 Developer ID 不改变 bundle ID、feed URL、Ed25519 key 或应用侧 updater 接口。
12. 首装材料不把同源 SHA-256 宣传为开发者身份认证，也不要求用户全局关闭 Gatekeeper。
13. 私钥丢失、完整性无法确认或疑似泄露时，发布链路停止且只能通过新的手动 bootstrap 恢复。
14. 已激活版本发生严重功能回归时可以停止后续发现，但不会删除不可变资产或声称已降级现有安装。

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
- [Sparkle CLI](https://sparkle-project.org/documentation/sparkle-cli/)
- [Sparkle appcast relative URL resolution](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUAppcastItem.m)
- [CodexBar Sparkle integration](https://github.com/steipete/CodexBar/blob/main/docs/sparkle.md)
- [GitHub Immutable Releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [GitHub release immutability settings](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
- [GitHub Contents API](https://docs.github.com/en/rest/repos/contents)
- [GitHub Actions secure use reference](https://docs.github.com/en/enterprise-cloud@latest/actions/reference/security/secure-use)
