# 重置历史与按月统计设计

> 2026-07-23 follow-up：Dashboard 月度图表已增加 `3m`、`6m`、`12m`、`all`
> 时间范围。固定滚动十二个月与“无自定义范围”的约束由
> `2026-07-23-dashboard-history-range-design.md` 覆盖，其余设计继续有效。

## 目标

为 Codex Radar 增加服务端权威的重置历史，并将客户端展示重点放在重置频率统计上：菜单栏显示最近一次重置时间，Dashboard 展示本周、本月次数、滚动十二自然月统计，以及最近五次重置。

服务端是历史事件的唯一权威来源。客户端不根据轮询状态自行推断或补写历史，也不在第一版持久化历史缓存。

## 范围

本设计覆盖两部分：

- `codex-radar-backend` 的权威事件模型、状态机写入语义、`/v1/current` 扩展和 `/v1/history` 查询契约。
- 当前 macOS 客户端的模型、服务、状态管理、菜单栏和 Dashboard 展示行为。

后端具体代码映射与迁移步骤由 `codex-radar-backend` 的同名后端规格定义。本文已经同步纳入后续 backend grilling 中确认的证据时间、bounded batch、回填和 ETag 修订；两份规格必须采用同一协议语义。

## 权威事件模型

服务端永久保存 `reset_history` 事件。每条记录代表服务端在一次归约中接受一个新的完成信号并形成 `completed` transition：

```text
id
source_signal_id
reset_at
created_at
```

字段和约束如下：

- `id` 是公开历史资源自身的稳定标识，不复用通知协议中的 `signal_id`。
- `source_signal_id` 对应状态首次进入 `completed` 时产生的信号 ID，并设置唯一约束。
- `reset_at` 是本次归约选定完成证据帖的 UTC 发布时间，是实际完成时间的可验证代理，写入后不可修改。
- `created_at` 是历史记录的持久化时间，用于审计，不参与用户统计。
- `reset_at` 建立支持最新记录和时间区间聚合的索引。
- 历史永久保留，不进行定时清理。

accepted completed transition 的 resultant snapshot 与插入历史记录必须位于同一原子边界。若完成证据的 current-state TTL 已过，历史仍记录该事实，而同批最终 snapshot 可以是 `monitoring`；不能为了留下 completed 状态而短暂展示过期的 `use_now`。事务重试、重复抓取和进程恢复均不得产生第二条记录；`source_signal_id` 唯一约束是最终幂等防线。重复写入冲突应按已成功记录处理，而不是把状态机转为失败。

一次 bounded batch 最多形成一条历史：只有一条 completed 证据时选择该帖；有多条时选择 `(created_at DESC, id DESC)` 的第一条。该规则同时适用于全新 Bootstrap、Collector 离线恢复和 X API 抓取，不在批内重建多个 lifecycle。后续证据、帖子、预测时间或相同语义状态更新不得修改已经写入的 `reset_at`。

V1 的 API 计数单位是服务端接受的 completed signal，不是经过独立验证的现实 reset identity。两个不同 signal 可能重复描述同一次现实重置并分别计数；一次 bounded batch 跨越多个现实重置时也可能只记录最新完成证据。这两项是已确认的 V1 限制。

这里的永久保留是应用级 retention：服务端不更新或删除已提交 row，也不提供 correction/tombstone。本阶段不承诺独立归档、备份或应用管理的副本。

## `/v1/current` 扩展

`GET /v1/current` 在现有响应中增加可空字段：

```json
{
  "schema_version": "1.1",
  "last_reset_at": "2026-07-19T08:21:34Z"
}
```

契约规则：

- `last_reset_at` 读取 `reset_history` 中最新事件的 `reset_at`，不能维护容易漂移的第二份状态。
- 没有历史事件时明确返回 `null`，不能省略字段。
- 响应 `ETag` 必须覆盖 `last_reset_at`；新增事件成为最新历史并改变该字段时，`ETag` 必须改变。补入不影响 `last_reset_at` 的更早历史时，current 表示和 ETag 都不改变。
- 新字段是向后兼容扩展：旧客户端可以忽略，新客户端按可空字段解码。
- 客户端仍按现有频率轮询 `/v1/current`，菜单栏不为最近重置时间增加独立请求。

## `/v1/history` 契约

Dashboard 使用以下查询获取统计和最近事件：

```http
GET /v1/history?time_zone=Asia%2FShanghai
```

响应示例：

```json
{
  "schema_version": "1.0",
  "generated_at": "2026-07-19T09:00:00Z",
  "time_zone": "Asia/Shanghai",
  "current": {
    "week": {
      "from": "2026-07-12T16:00:00Z",
      "to": "2026-07-19T16:00:00Z",
      "count": 2
    },
    "month": {
      "from": "2026-06-30T16:00:00Z",
      "to": "2026-07-31T16:00:00Z",
      "count": 6
    }
  },
  "months": [
    { "month": "2025-08", "from": "2025-07-31T16:00:00Z", "to": "2025-08-31T16:00:00Z", "count": 0 },
    { "month": "2025-09", "from": "2025-08-31T16:00:00Z", "to": "2025-09-30T16:00:00Z", "count": 0 },
    { "month": "2025-10", "from": "2025-09-30T16:00:00Z", "to": "2025-10-31T16:00:00Z", "count": 1 },
    { "month": "2025-11", "from": "2025-10-31T16:00:00Z", "to": "2025-11-30T16:00:00Z", "count": 0 },
    { "month": "2025-12", "from": "2025-11-30T16:00:00Z", "to": "2025-12-31T16:00:00Z", "count": 2 },
    { "month": "2026-01", "from": "2025-12-31T16:00:00Z", "to": "2026-01-31T16:00:00Z", "count": 3 },
    { "month": "2026-02", "from": "2026-01-31T16:00:00Z", "to": "2026-02-28T16:00:00Z", "count": 0 },
    { "month": "2026-03", "from": "2026-02-28T16:00:00Z", "to": "2026-03-31T16:00:00Z", "count": 1 },
    { "month": "2026-04", "from": "2026-03-31T16:00:00Z", "to": "2026-04-30T16:00:00Z", "count": 0 },
    { "month": "2026-05", "from": "2026-04-30T16:00:00Z", "to": "2026-05-31T16:00:00Z", "count": 2 },
    { "month": "2026-06", "from": "2026-05-31T16:00:00Z", "to": "2026-06-30T16:00:00Z", "count": 1 },
    { "month": "2026-07", "from": "2026-06-30T16:00:00Z", "to": "2026-07-31T16:00:00Z", "count": 6 }
  ],
  "recent": [
    {
      "id": "01K0EXAMPLE",
      "reset_at": "2026-07-19T08:21:34Z"
    }
  ]
}
```

### 查询参数

- `time_zone` 是客户端当前 IANA 时区。客户端必须显式传入，服务端不能用固定 UTC offset 代替。
- `year` 不再是协议参数；第一版不提供年份筛选或年度归档视图。
- 无效 IANA 时区、重复参数或额外 query 参数返回结构化 `400`。

### 统计语义

- 自然周固定从当地周一 `00:00` 到下周一 `00:00`。
- 自然月从当地每月一日 `00:00` 到下月一日 `00:00`。
- 所有统计区间采用 `[from, to)`，先在 IANA 时区中构造边界，再转换为 UTC 查询，以正确处理夏令时。
- `current.week` 和 `current.month` 始终表示请求发生时的本周和本月。
- `months` 固定返回以当前月为最后一项的滚动十二自然月，按时间升序排列，包括 `count` 为零的月份；它不是当前自然年或最近 365 天。
- `current.month` 与 `months` 最后一项必须具有完全相同的 `from`、`to` 和 `count`；服务端复用同一次当前月统计，客户端解码时验证该不变量。
- `recent` 固定返回全局最近五条事件，按 `(reset_at DESC, id DESC)` 稳定排序。
- `current`、`months` 和 `recent` 应读取同一个一致数据库快照，避免单次响应内部出现时间视图分裂。

第一版不提供 cursor 或完整历史分页。完整事件永久保留，但只作为最近五条与聚合统计的数据源。

### 错误响应

- 参数错误返回结构化 `400`。
- 服务暂不可用返回结构化 `503`。
- 首次 Bootstrap 尚未完成时返回结构化 `503 not_initialized`，不能用成功的全零统计表示尚未开始采集；Bootstrap 完成后空 history 才是权威零统计。
- forecast 与 history 是独立错误域；任一接口失败不能覆盖另一接口的有效数据。

## 后端数据流与上线

一次新重置的核心路径如下：

1. 监控状态机在归约中接受新的 completed signal；一次 bounded batch 最多选择一个 canonical history candidate。
2. 服务端生成或取得该 completed transition 的 `source_signal_id`。
3. 在同一原子边界内提交 resultant snapshot，并用所选证据帖时间插入 `reset_history`；证据 TTL 已过时 resultant snapshot 可以是 `monitoring`。
4. 新事件成为最新历史时，`/v1/current.last_reset_at` 和 ETag 随之变化。
5. 后续 `/v1/history` 查询从权威表计算本周、本月、滚动十二自然月与最近五条。

上线时如果已有 `completed` 状态，只加载 snapshot，不写历史；历史表为空是允许且可正确展示的初始状态。V1 不实现回填 endpoint、CLI、helper 或发布脚本。未来若取得能够重建原始归约输入并证明 canonical history candidate 的权威记录，必须另行设计一次性维护部署；只有 bounded snapshot evidence 或最终 `source_url` 时不足以执行，且不能使用任意保留帖子、预测时间、snapshot `expires_at`、部署时间或恢复时间替代。

## macOS 客户端架构

### 当前 forecast

现有 `ResetForecast` 增加 `lastResetAt: Date?`，编码键为 `last_reset_at`，同时在解码时保留字段是否存在的内部状态。新版响应中字段存在且值为 `null` 才表示服务端权威确认“暂无记录”；旧响应缺少该字段表示服务端尚未提供此能力，客户端显示暂不可用而不是暂无记录。这样既能继续解码旧响应，也不会在滚动升级期间误报历史为空。

`ResetForecastService` 继续负责 `/v1/current` 与 `ETag`。请求成功时更新内存中的 `lastResetAt`；`304` 或请求失败时保留当前 forecast。因此，同一次应用运行期间已经取得的最近重置时间不会因短暂网络错误消失。

### 历史统计

新增以下边界：

- `ResetHistoryService`：构造只包含 IANA 时区的 `/v1/history` 请求并解码响应。
- `ResetHistoryStore`：管理统计、滚动十二个月数据、最近五条、加载状态和独立错误。
- `ResetHistoryPresentation`：集中处理本地化日期、月份标签、空态和辅助功能文案。

第一版不增加 `ResetHistoryCache`，所有 history 数据只保存在当前进程内。应用重启后重新从服务端加载。

`ResetHistoryStore` 使用请求 generation 隔离 Dashboard 重进、手动刷新、时区变化、自然边界刷新和 reset-change reload 的并发，旧响应不得覆盖更新请求。刷新失败时继续展示上一个完整结果并提示错误。

每次成功响应后，Store 以服务端 `generated_at` 和响应时区计算下一个当地周一 `00:00` 与下个月一日 `00:00`，在较早边界后一秒安排单次 history 刷新。该定时器只用于让本周、本月和滚动十二自然月跨边界，不是固定间隔轮询；Dashboard 隐藏时取消，重新显示或时区变化时基于最新响应重建。边界刷新若与手动刷新或 reset-change reload 重叠，仍沿用 generation 与合并规则，只提交最新完整响应。

## 请求触发规则

`/v1/history` 只在 Dashboard 活动时请求：

- Dashboard 从非活动状态切换为活动状态时请求当前时区的 history。
- Dashboard 总刷新时，与 forecast 和 token usage 并发刷新。
- Dashboard 持续活动并跨过下一个当地周界或月界时，触发一次 history 边界刷新。
- Dashboard 保持活动时，如果 `/v1/current.last_reset_at` 变为更新的值，合并触发一次 history 重载，以更新本周、本月、月份图和最近五条。
- `reset_at` 早于当前 latest 的新 row 不会改变 `/v1/current.last_reset_at`，因此不触发实时重载；这既包括未来一次性维护，也包括延迟到达的 completed signal。该数据在 Dashboard 下次激活、总刷新、自然边界刷新或其他实际 history 请求时出现。
- 客户端不观察 completed `signal_id`，也不构造复合 history revision token；signal-only 变化不触发 history reload，这是为保持 V1 简单而接受的短暂陈旧窗口。
- Dashboard 不活动时取消未完成的 history 请求，不因 `/v1/current` 更新发起 history 请求。
- Dashboard 不活动时也取消自然边界定时器；再次活动后由新响应重新安排。
- `/v1/history` 不进行每分钟轮询。

手动刷新与自动重载需要合并，避免同一时区产生重复并发请求。

## 菜单栏设计

菜单栏“下次重置预测”卡片中，原状态说明副文案被最近一次重置时间完全替换：

- 有记录时只显示本地化绝对日期和时间，不增加“最近重置”标签。
- 新版响应中已成功确认 `last_reset_at` 字段存在且为 `null` 时显示“暂无重置记录”。
- 兼容旧响应但缺少 `last_reset_at` 字段时显示“重置时间暂不可用”。
- 首次请求进行中且尚无结果时显示“正在获取重置时间”。
- 首次请求失败且没有可保留的内存结果时显示“重置时间暂不可用”。
- forecast 为 stale 时仍显示内存中已有的最近重置时间；预测来源健康状态不能覆盖已确认的历史事实。

菜单栏不请求 `/v1/history`，也不展示周、月统计。

## Dashboard 设计

Dashboard 使用单列阅读流，顺序固定为：

1. 下次重置预测卡片。
2. 本周、本月两个次数统计卡片。
3. 以当前月结尾的滚动十二自然月柱状总览，每根柱直接标出次数。
4. 最近五次重置的紧凑时间列表。
5. Token 用量。

交互和状态规则：

- 最近列表只展示本地化日期和时间，不提供加载更多。
- 无历史时本周、本月及十二个月次数均为零，最近列表显示“暂无重置记录”。
- 首次 history 加载失败时显示独立错误空态和重试入口。
- 已有内存结果后刷新失败时保留当前统计和最近五条，并显示非阻断错误。
- history、forecast 和 token usage 分别维护错误状态；刷新一个子系统不能清除其他子系统的错误。

## 验证

### 服务端

- 单一 completed 证据精确写入一条历史；同一 bounded batch 有多条 completed 证据时最多写入一条并选择最新证据帖。
- Bootstrap 或延迟恢复接受已超过 current-state TTL 的 completed 证据时写入历史，但最终 current 保持 `monitoring`，不展示过期 `use_now`。
- 重复抓取、事务重试和进程恢复不产生重复事件。
- 每个 completed `source_signal_id` 最多一条历史；不同 signal 不承诺自动关联到同一现实 reset。
- `/v1/current.last_reset_at` 与最新历史事件一致；新增最新事件改变 ETag，补入更早事件不改变 current ETag。
- V1 不暴露回填 endpoint、CLI 或 helper；已有 completed snapshot 只加载、不写入历史。
- `recent` 最多五条，并按稳定倒序返回。
- 始终返回以当前月结尾的十二个连续自然月，包括零次数月份。
- 覆盖周一边界、月末、年末、闰年和夏令时切换。
- 覆盖无历史、无效时区、额外参数和服务不可用响应。
- 覆盖 Bootstrap 前 `503 not_initialized`，以及 Bootstrap 后空表的成功零统计。
- 验证一次 `/v1/history` 响应中的各部分来自一致快照。

### macOS 客户端

- `/v1/current` 新字段的可空解码与旧响应兼容，并能区分字段缺失和明确 `null`。
- 菜单栏覆盖有时间、无记录、首次加载、首次失败和保留内存结果状态。
- Dashboard 未活动时不请求 `/v1/history`。
- Dashboard 激活、总刷新、时区变化、当地周/月边界和新 reset 到达触发正确请求。
- 乱序响应、重复触发和失败保留不会提交不一致状态。
- 自然边界刷新安排在服务端时间的边界后一秒；隐藏 Dashboard 会取消，重进会重建，和手动/reset-change 请求重叠时不会重复提交。
- completed `signal_id` 单独变化而 `last_reset_at` 不变时不自动重载；后续激活、总刷新或自然边界刷新会取得新增的较早 row。
- 十二个月数据、最近五条和空态 presentation 正确；客户端拒绝 `current.month` 与最后一个 month bucket 不一致的响应。
- 中英文、Light/Dark Mode、时区变化和辅助功能标签人工验证通过。
- 完整 Swift 测试和 debug build 通过。

## 非目标

第一版不包含：

- 完整历史浏览或分页。
- 历史导出。
- 自定义日期范围。
- 年份选择器或按自然年浏览。
- 滚动七天或三十天统计。
- 预测准确率分析。
- 单条事件详情与来源帖子。
- 客户端本地持久化缓存。
- 回填 API、CLI 或通用回填工具。
