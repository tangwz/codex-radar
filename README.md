# Codex Radar

一个以 menu bar 为主的 macOS 14+ SwiftUI 应用，用于观察 Codex 重置公告、预测和本地 token 消耗。

## 功能

- 客户端直接读取 Codex Resets 公共 `/api/v1/status` 和 `/api/v1/resets`，不需要自建后端、代理、X 凭证或账户 Token。
- 最新公告与预测分别处理；预测过期时间不作为实际重置倒计时，公告也不代表个人账户额度已经恢复。
- 完整读取历史分页后，在本地按用户时区汇总自然周、自然月和最近 30 天记录。
- 公共响应使用磁盘缓存和 ETag，遵守 Cache-Control、Age 与 Retry-After。请求失败时可显示已缓存状态并标记过期，不触发提醒。
- 首次安装或从旧后端迁移时建立独立通知基线，不补发旧公告，包括被预测遮挡的已有公告；后续按来源和事件 ID 去重。
- 只读扫描 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/*.jsonl`，使用版本化本地缓存复用未变化文件的解析结果；不上传本地日志。
- 按日、月、年展示 total、input 和 output；当前周期指标与趋势图同步切换，柱状图通过鼠标悬浮展示明细。
- 参考 CodexBar 的累计快照、interleaved counter 与稳定 session identity 处理；统计为本地日志推算值，不依赖 CodexBar 运行时。
- 支持跟随系统、English 和简体中文。
- 支持 Light/Dark Mode，并使用 Sparkle 2.9.4 提供签名自动更新。

数据来自第三方 Codex Resets，不是 OpenAI 账户额度接口。实测状态响应曾返回四小时的客户端缓存有效期，因此分钟级界面刷新不等于分钟级网络请求或即时通知。`generated_at` 也不能证明上游采集器持续健康。应用退出时不提供服务端推送。

历史请求失败时保留已打开 Dashboard 的历史快照；重新启动且历史缓存过期、网络不可用时，不把不完整或过期分页伪装成最新历史。详细语义见 [`docs/codex-resets-migration.md`](docs/codex-resets-migration.md)。

## 运行

```bash
./script/build_and_run.sh
```

应用会构建到 `dist/CodexRadar.app`。也可以使用 Codex 的 Run action 启动。

## 下载与首次安装

当前公开版本是 [CodexRadar v0.1.4](https://github.com/tangwz/codex-radar/releases/tag/v0.1.4)。下面的资产仍是此前发布版本；本分支的公共 API 迁移尚未发布。旧客户端仍依赖旧接口，迁移上线前不要直接关闭旧后端。

下载版本固定的 Universal ZIP <https://github.com/tangwz/codex-radar/releases/download/v0.1.4/CodexRadar-v0.1.4-macos-universal.zip>
和对应的 SHA-256 文件 <https://github.com/tangwz/codex-radar/releases/download/v0.1.4/CodexRadar-v0.1.4-macos-universal.zip.sha256>，然后校验：

```bash
curl -LO https://github.com/tangwz/codex-radar/releases/download/v0.1.4/CodexRadar-v0.1.4-macos-universal.zip
curl -LO https://github.com/tangwz/codex-radar/releases/download/v0.1.4/CodexRadar-v0.1.4-macos-universal.zip.sha256
shasum -a 256 --check CodexRadar-v0.1.4-macos-universal.zip.sha256
```

SHA-256 只能确认下载字节与该 Release 资产一致，不能证明开发者身份。当前应用是 ad-hoc signed，不是 Developer ID signed，也未 notarized；首次手动下载与 GitHub 分发渠道仍是独立的引导信任边界。

校验通过后解压 ZIP，并把 `CodexRadar.app` 移到 `/Applications` 或 `~/Applications`。首次启动只使用以下单应用流程之一：

1. 在 Finder 中按住 Control 点击 `CodexRadar.app`，选择 Open，再确认 Open。
2. 如果 macOS 阻止启动，打开 System Settings > Privacy & Security，仅对刚被阻止的 `CodexRadar.app` 选择 Open Anyway。

不要关闭或全局降低 Gatekeeper。首次成功启动后，后续自动更新由应用内置的 Sparkle Ed25519 公钥验证。

## 测试

安装完整 Xcode 时，从仓库根目录运行唯一的完整 Swift 测试入口：

```bash
./script/test.sh
```

入口无需参数，会以稳定的两阶段编排运行全部 Swift 测试并隔离 AppKit-facing suites。仅安装当前 Command Line Tools 时，`Testing.framework` 可能不在默认搜索路径，因此推荐使用完整 Xcode。

## 发布

发布链分为 Candidate 准备和 Production Update 激活两个阶段。修改并提交 `version.env` 后，从 `main` 创建匹配的 `v<MARKETING_VERSION>` tag；`Prepare Update Candidate` 负责生成并签名 Draft Release。真实 Mac 资格测试通过后，再手动运行 `Publish Update` 公开不可变资产并以 compare-and-swap 激活 signed appcast。

完整的环境配置、密钥迁移、资格测试、失败恢复和 Distribution Halt 操作见 [`docs/releasing.md`](docs/releasing.md)。
