# GitHub Review Follow-up Design

## 目标

处理 PR #1 最新一轮 review：修复两个经验证成立的问题，并对两个与既定服务端协议冲突的重复意见给出技术说明。改动保持在 macOS 客户端范围，不复制后端状态机语义，也不改变 `/v1/current` 公共协议。

## 评审结论

### 保持现状

- 通知去重继续只使用 `signal_id`。服务端在 announced timing 变化或状态首次进入 `completed` 时生成新的 `signal_id`；相同语义状态的新证据保持原 ID。客户端组合 status 或 timing 会重复服务端身份逻辑，并增加重复通知风险。
- 客户端拉取失败不改写 `forecast.stale`。`stale` 由服务端根据数据源五分钟健康窗口统一判定；客户端仅保留最后有效快照、展示暂时不可用问题并执行退避重试。

### 修复通知提前消费

`ResetNotificationService` 仅在通知成功加入系统通知中心后持久化新的 `signal_id`。权限未确定、未授权或通知中心临时失败时，旧 baseline 保持不变。

为了让未成功投递的信号有重试机会，`DashboardStore` 在收到 `304 Not Modified` 时也把当前 forecast 交给通知观察逻辑。已成功投递的 ID 会被现有策略立即忽略，因此不会产生重复通知。

通知投递通过一个可注入的异步 closure 与 baseline 状态解耦。生产环境仍使用 `UNUserNotificationCenter`；测试环境可以确定性模拟投递失败和成功，无需操作系统权限弹窗。

## 修复本地化错误身份

`DashboardStore` 增加一个语义明确的 forecast issue 槽位，保存当前由 forecast 子系统产生的已渲染消息。新增、替换和清除 forecast issue 都通过该槽位完成，不再用当前语言下的字符串前缀搜索 `issues`。

完整刷新开始时只保留该 forecast issue，并清除上一轮 token usage issue，维持当前 UI 行为。语言切换后，下一次 forecast 成功可以精确删除旧语言消息；下一次失败则先删除旧消息，再加入当前语言的新消息。

本次不把所有 issue 重构为强类型模型。当前只有 forecast issue 需要跨刷新稳定身份，全量重构会扩大 PR 范围，但语义槽位为以后迁移到 typed issue 保留了清晰边界。

## 数据流与错误处理

1. 新 forecast 到达后，通知策略判断是否为新的可通知 `signal_id`。
2. 若需要通知，客户端尝试投递；只有成功后才更新 baseline。
3. 若投递失败，下一次 updated 或 not-modified 响应会再次观察该 forecast。
4. forecast 拉取失败只更新失败计数和 forecast issue，不修改最后有效 forecast。
5. forecast 拉取恢复后，按槽位清除 forecast issue，不受当前界面语言影响。

## 测试

- 通知投递失败后不消费 signal；相同 signal 再次观察时继续投递。
- 通知投递成功后消费 signal；相同 signal 再次观察时被忽略。
- `304 Not Modified` 会重新观察当前 forecast，为失败投递提供重试入口。
- forecast issue 在一种语言下产生、切换语言后成功恢复时可以被清除。
- forecast issue 在一种语言下产生、切换语言后再次失败时仍保持单条，并更新为当前语言文案。
- 运行完整 Swift 测试，确认轮询并发、baseline、presentation 与现有菜单栏行为没有回归。

## 非目标

- 不改变服务端 Signal ID、TTL 或 stale 语义。
- 不在客户端增加独立的通知重试计时器。
- 不阻塞初始 forecast 拉取等待通知授权。
- 不重构所有 UI issue 为新的公共模型。
