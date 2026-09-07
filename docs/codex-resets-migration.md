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
Age, ETag/304, no-store, delta-seconds Retry-After and exponential retry delays.

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
