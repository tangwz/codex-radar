# Codex Radar

一个以 menu bar 为主的 macOS 14+ SwiftUI 应用，用于观察 Codex 重置信号和本地 token 消耗。

## 功能

- 从公开 reset alert RSS 读取最新官方窗口，并直接展示原始 X 来源。
- reset window 激活时显示菜单栏红点，并发送一次 macOS 通知。
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
