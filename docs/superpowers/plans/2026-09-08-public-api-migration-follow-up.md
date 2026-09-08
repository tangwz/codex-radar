# Public API Migration Follow-up Implementation Plan

> **For agentic workers:** 按任务顺序执行，每项完成后验证对应行为。

**Goal:** 完成 PR #30 中提醒和历史统计的公共 API 迁移及其联动。

**Architecture:** 沿用 `CodexResetsHTTPClient`、公共响应模型和本地历史投影。通知按本机首次观察时间建立静默基线；历史刷新以最新公告 ID、时间和总数为依据，独立于当前预测信号。

**Tech Stack:** Swift 6、SwiftUI、Foundation、Swift Testing；macOS 14+。

## Constraints

- 延续 PR #30 已有方案，接口为 `/api/v1/status`、`/api/v1/resets`。
- 所有历史分页成功后才发布本地聚合，保留用户时区和自然日语义。
- API 数据是第三方公告和预测；不代表个人账户额度恢复。
- 本轮边界是迁移客户端的正确性，发布和旧后端下线仍独立处理。

## Tasks

- [ ] HTTP 缓存：为旧 `Date`、低估 `Age`、请求耗时和 304 续期补回归用例；将原始缓存寿命与剩余寿命分开，按 RFC 9111 计算当前年龄。
- [ ] HTTP 重试：覆盖 429/503 的秒数及 HTTP 日期格式，校验其他公共端点也遵守冷却时间；无效值回退到已有指数退避。
- [ ] 通知：覆盖上游缓存隐藏的启动前公告与预测、启动后新信号、重启去重和 stale 首次响应；使用可注入本机时钟和信号观察时间。
- [ ] 统计刷新：为公告 ID 和总数建立 `ResetHistoryRevision`，贯穿公共响应、Dashboard 和 `ResetHistoryStore`；覆盖同时间不同 ID、预测遮挡、总数变更和请求合并。
- [ ] 菜单正文：显示公共预测及窗口，保持来源与预测说明可见。
- [ ] 更新迁移说明；检查生产网络入口不存在旧后端 URL。
- [ ] 执行聚焦回归、标准 `./script/test.sh`、严格并发构建和结构化代码审查；验证后更新 PR 分支。

## Verification

```sh
swift test --no-parallel --filter 'CodexResetsHTTPClientTests|CodexResetsNotificationTests|ResetHistoryStoreTests|CodexResetsMigrationTests'
./script/test.sh
swift build -Xswiftc -strict-concurrency=complete
git diff --check
.agents/skills/autoreview/scripts/autoreview --mode branch --base origin/main
```
