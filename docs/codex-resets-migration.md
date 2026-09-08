# Direct public API migration

## Scope

The macOS client directly reads Codex Resets `/api/v1/status` and
`/api/v1/resets`; it no longer calls the owned Worker endpoints. No cloud proxy,
secondary backend, X credential, or account token is required. Local token
statistics, application signing and update distribution are unchanged.

The public OpenAPI document and real status/history responses were inspected
on 2026-09-07. This third-party service supplies announcements and predictions,
not verified account quota changes.

## Data semantics

`announced_at` is the announcement or first-observation time. Regular and banked
records are counted separately. The first public-history metric is their sum,
not the legacy backend's combined-event subset. Opaque event IDs need not be X
post IDs; source links are taken from validated response fields.

A valid watch newer than the latest announcement is shown as a prediction.
Its free-text window and expiration never become a reset countdown. Announcements
remain actionable for a local 24-hour UI window, then remain in history without
permanently lighting the badge. No public event maps to account-ready/completed.

Every history page is required before publishing new totals. Repeated/missing
cursors, conflicting duplicate IDs and a 100-page safety limit are explicit
errors, not partial successful results. Counts use local natural months,
Monday-based weeks and 30 natural days, including daylight-saving transitions.

## Availability and privacy

Validated public responses are cached locally with bounded atomic disk writes.
No account/session content is sent upstream. The HTTP client uses an ephemeral
session without cookie or credential storage. It respects private max-age,
Age, ETag/304, no-store, Retry-After and exponential retry delays.

IMPORTANT: the observed status response had max-age=14400 (four hours). The
existing minute refresh loop is not a promise of minute-by-minute upstream
requests or notifications; it must honor the service's cache policy. Generation
time and HTTP success are not proof of upstream collector health.

Cached status returned after an upstream error is marked stale and cannot light
the badge or notify. Forecast expiration is reevaluated even on cache hits and
304 responses. Failed history refreshes retain an already-open dashboard's last
complete snapshot with its existing error state; expired historical responses
are not represented as fresh after an offline restart.

The first fresh snapshot establishes a provider-specific notification baseline.
Legacy consumed IDs are retained, while public event IDs are provider-namespaced.
Notifications do not run as server-side push while the application is stopped.

## Rollout

This migration does not delete, stop, archive or redeploy the existing backend.
Old installed clients still require it until a new signed client version has
been qualified, released and adopted. The PR does not change the production
appcast, version, signing keys or release activation.

Run `./script/test.sh` with full Xcode for the canonical suite. A focused migration
suite runs on macOS CI. Record the exact tested commit and any unrelated AppKit
failures in the PR. Visual/notification behavior still needs real-Mac release
qualification. Record the latest exact commit and results in the PR rather than
assuming that a successful build also validates interactive behavior.

The history picker, chart tooltips, accessibility labels and radar legend use
bilingual announcement wording. All announcements is regular plus banked, not
the old simultaneous-reset subset. Mixed days mean two types were recorded on
one local day, not that account quota arrived simultaneously. Settings disclose
the third-party source, server-controlled caching and lack of polling after quit.

The AppKit test fixture owns its NSWindow through Swift ARC and explicitly sets
isReleasedWhenClosed=false before close(). This avoids over-release during test
teardown; the window visibility/accessibility assertions and standard test entry
point are retained. No production window behavior or CI gate is bypassed.

## 2026-09-08 后续修正

- 通知基线以本机首次观察到有效快照的时间建立，避免上游缓存隐藏的启动前公告或预测在缓存更新后补发；基线和已消费信号跨重启保留。
- 统计刷新同时比较最新公告 ID、公告时间和上游总数。预测展示与历史修订独立，同时间的不同公告、总数变化都可触发刷新，预测过期本身不会额外刷新历史。公告变化会对全部历史分页做 ETag 条件重验证，避免仍然复用旧统计缓存；普通查询继续复用有效缓存，重验证也遵守限流冷却。
- 统计保留最后一次完整加载对应的公告版本；窗口关闭期间的新公告、关闭窗口取消的重验证，都将在再次打开时继续处理。
- 菜单卡片展示公共消息正文与预测窗口，保留第三方来源及预测说明；长正文可通过悬浮提示查看。
- HTTP 缓存按 `Date`、`Age` 和请求耗时计算剩余寿命；304 缺省缓存策略时复用原始 `max-age`，不重复扣减上一响应的年龄。限流同时支持秒数和标准 HTTP 日期形式的 `Retry-After`，无效或已过去的值保留本地退避。
