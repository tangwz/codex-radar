# Codex Radar

一个以 menu bar 为主的 macOS 14+ SwiftUI 应用，用于观察 Codex 重置信号和本地 token 消耗。

## 功能

- 每分钟读取公开的 `/v1/current`，展示 Tibo 的 reset 状态、时间和原始 X 证据。
- 仅在数据非 stale 且 reset 状态为 announced 时显示菜单栏红点。
- 首次进入 announced、announced timing 变化和首次进入 completed 时，各发送一次 macOS 通知。
- 只读扫描 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/*.jsonl`。
- 按日、月、年聚合 input、output、cached input 和 total token。
- 参考 CodexBar 的累计快照、interleaved counter 与稳定 session identity 处理；统计为本地日志推算值，不依赖 CodexBar 运行时。
- 支持跟随系统、English 和简体中文。
- 支持 Light/Dark Mode，不需要额外 Swift package 依赖。

## 运行

```bash
./script/build_and_run.sh
```

应用会构建到 `dist/CodexRadar.app`。也可以使用 Codex 的 Run action 启动。

## 测试

安装完整 Xcode 时直接运行：

```bash
swift test
```

仅安装当前 Command Line Tools 时，`Testing.framework` 可能不在默认搜索路径，需要为测试命令补充 framework 和 runtime 路径。

## 发布

发布版本前必须先修改并提交 `version.env`。其中 `MARKETING_VERSION` 必须使用 `MAJOR.MINOR.PATCH` 格式，`BUILD_NUMBER` 必须是正整数；两者是应用和发布产物版本的唯一来源。

当前采用两阶段策略：

- 在 `main` 上手动运行 GitHub Actions 的 `Release`，属于 package-only/preflight：它构建、签名、验证并保留七天 Artifact，但不会创建 GitHub Release。
- 手动 ad-hoc preflight 必须选择 `signing_mode=adhoc` 和 `release_channel=prerelease`；`adhoc + stable` 会 fail closed。Artifact 是 ad-hoc 签名且未公证的预检产物。手动选择 `developer-id` 时，会真实执行 Developer ID 签名并向 Apple 提交公证、等待并 stapling；它仍然只生成 Artifact，不创建 GitHub Release。
- 推送位于 `main` 历史中的 `v*` tag 时，工作流固定创建 ad-hoc 签名、未公证的 GitHub Pre-release。它不会根据已有 secrets 自动切换为 Developer ID 或 stable 发布。
- 在 Apple Developer Program 凭据和受保护的 `release` Environment 完整配置之前，Developer ID 分发保持禁用。未来只有通过可审阅的显式配置切换到 `developer-id` 后，才能发布 stable Developer ID 版本。

推荐按照以下顺序操作：

1. 修改 `version.env`，提交版本变更，并将该提交合入 `main`。
2. 在 `main` 手动运行 `Release`，优先选择 `adhoc` 做 package-only/preflight；下载七天 Artifact，确认没有创建 GitHub Release。
3. 对同一 `main` 提交创建与 `MARKETING_VERSION` 完全一致的 tag。`v0.1.0` 之类的 tag 必须指向已经包含在 `main` 中的提交。
4. 推送 tag，等待 ad-hoc GitHub Pre-release 创建完成。

在本地创建 tag 前，可先确认版本元数据和当前提交已进入远端 `main`：

```bash
git fetch origin main
./script/validate_release.sh
git merge-base --is-ancestor HEAD origin/main
```

本地也可以先生成与工作流相同的 ad-hoc 发布产物：

```bash
SIGNING_MODE=adhoc RELEASE_PRERELEASE=true \
  ./script/package_release.sh dist/release
```

当前版本的发布资产为 ZIP `CodexRadar-v<MARKETING_VERSION>-macos-universal.zip` 及同名 `.zip.sha256`。打包脚本不会清理输出目录中的旧版本资产，建议使用空输出目录，或在验证时只选择当前版本的这两个文件。发布或下载 Artifact 后，在这两个文件所在目录验证 checksum：

```bash
/usr/bin/shasum -a 256 --check CodexRadar-v0.1.0-macos-universal.zip.sha256
```

确认 `version.env` 已合入 `main` 且预检成功后，再创建并推送 tag：

```bash
git tag -a v0.1.0 -m "CodexRadar v0.1.0"
git push origin v0.1.0
```

发布脚本不会自动覆盖已经公开的 tag 或 GitHub Release。构建、测试、签名或验证失败时不会创建 Release；资产上传失败时会保留 Draft，避免暴露不完整产物。只可对同一 tag 的 Draft 安全重跑，重跑会重新上传同名资产；一旦 Release 已公开，脚本会拒绝覆盖，必须停止并按新的版本/tag 或经人工审核的修复流程处理。

推送第一个发布 tag 前，仓库管理员还必须启用一个针对 `v*` 的 active tag ruleset，至少禁止 tag update 和 delete，并严格限制或取消管理员/其他 bypass。workflow 会在 metadata、ad-hoc 打包前和发布调用前分别从远端重新读取并核对 tag commit，但这些检查与后续操作无法组成原子事务；tag ruleset 是关闭最后一次检查后的瞬时竞态、tag 移动/删除以及管理员重跑风险所需的外部边界。仓库内检查不能替代该 ruleset，也不应声称可以完全消除竞态。

Developer ID 手动 preflight 前，仓库管理员必须在 GitHub 预先创建 `release` Environment。在 deployment branches/tags 中分别添加 deployment Branch rule `main` 与 Tag rule `v*`，配置 required reviewer、开启 prevent self-review，并取消勾选 `Allow administrators to bypass configured protection rules`。还必须配置以下五项 secrets：

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

这些 Environment 规则是仓库外部的发布前置条件；本地脚本和 `main` 祖先校验不能替代 reviewer 审批或管理员绕过保护。不要在本地或 workflow 日志中输出任何证书、密码或 App Store Connect 凭据。
