# Codex Radar

一个以 menu bar 为主的 macOS 14+ SwiftUI 应用，用于观察 Codex 重置信号和本地 token 消耗。

## 功能

- 每分钟读取公开的 `/v1/current`，展示 Tibo 的 reset 状态、时间和原始 X 证据。
- 从 `/v1/current` 展示服务端确认的最近一次重置时间；旧协议缺字段、明确无历史与暂时不可用使用不同状态。
- Dashboard 打开时读取 `/v1/history`，按用户时区展示本周、本月、所选历史范围的月度统计和最近五次重置。
- 数据非 stale 且 reset 状态为 candidate、announced 或 completed 时显示菜单栏红点；红点表示当前服务端状态，不表示未读。
- 对首次观察到的 candidate、announced 或 completed signal ID 最多发送一次 macOS 通知；首次安装或升级只建立 baseline，不补发已有信号。
- 只读扫描 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/*.jsonl`，使用版本化本地缓存复用未变化文件的解析结果。
- 按日、月、年展示 total、input 和 output；当前周期指标与趋势图同步切换，柱状图通过鼠标悬浮展示明细。
- 参考 CodexBar 的累计快照、interleaved counter 与稳定 session identity 处理；统计为本地日志推算值，不依赖 CodexBar 运行时。
- 支持跟随系统、English 和简体中文。
- 支持 Light/Dark Mode，并使用 Sparkle 2.9.4 提供签名自动更新。

## 运行

```bash
./script/build_and_run.sh
```

应用会构建到 `dist/CodexRadar.app`。也可以使用 Codex 的 Run action 启动。

## 下载与首次安装

当前尚无可下载的公开 Release。

首个 bootstrap Production Update 公开并激活后，本节会提供不可变的版本固定 ZIP、SHA-256 资产及对应校验命令，不会使用 `latest/download`。

SHA-256 只能确认下载字节与该 Release 资产一致，不能证明开发者身份。当前应用是 ad-hoc signed，不是 Developer ID signed，也未 notarized；首次手动下载与 GitHub 分发渠道仍是独立的引导信任边界。

校验通过后解压 ZIP，并把 `CodexRadar.app` 移到 `/Applications` 或 `~/Applications`。首次启动只使用以下单应用流程之一：

1. 在 Finder 中按住 Control 点击 `CodexRadar.app`，选择 Open，再确认 Open。
2. 如果 macOS 阻止启动，打开 System Settings > Privacy & Security，仅对刚被阻止的 `CodexRadar.app` 选择 Open Anyway。

不要关闭或全局降低 Gatekeeper。首次成功启动后，后续自动更新由应用内置的 Sparkle Ed25519 公钥验证。

## 测试

安装完整 Xcode 时直接运行：

```bash
swift test
```

仅安装当前 Command Line Tools 时，`Testing.framework` 可能不在默认搜索路径，需要为测试命令补充 framework 和 runtime 路径。

## 发布

发布链分为 Candidate 准备和 Production Update 激活两个阶段。修改并提交 `version.env` 后，从 `main` 创建匹配的 `v<MARKETING_VERSION>` tag；`Prepare Update Candidate` 负责生成并签名 Draft Release。真实 Mac 资格测试通过后，再手动运行 `Publish Update` 公开不可变资产并以 compare-and-swap 激活 signed appcast。

完整的环境配置、密钥迁移、资格测试、失败恢复和 Distribution Halt 操作见 [`docs/releasing.md`](docs/releasing.md)。
