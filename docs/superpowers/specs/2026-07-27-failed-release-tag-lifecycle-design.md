# 失败发布 Tag 生命周期设计

## 背景

仓库的 `Protect immutable release tags` ruleset 覆盖 `refs/tags/v*`，禁止更新和删除匹配的 tag，且不配置 bypass actor。现有发布流程却在 Candidate 资格测试失败和公开 Release 复验失败时删除 Release 与 tag，导致文档、workflow 与 GitHub 实际执行策略冲突。

本设计保留严格的 tag 不可变边界：任何 `v*` tag 一经创建即永久保留。失败发布通过提升版本并创建新 tag 继续，不通过删除、移动或复用旧 tag 恢复。

## 目标

- 使 workflow、测试、发布手册和 GitHub ruleset 对失败恢复采用同一语义。
- 保证 `v*` tag 从 Candidate 开始直到 Production Update 全生命周期不可更新、不可删除。
- 失败版本的 Release 资产不继续作为有效候选分发。
- 为 Release Operator 提供可执行且不会被 ruleset 拒绝的恢复步骤。
- 保持 Production Feed 的 compare-and-swap 激活与 Activation Pending 语义不变。

## 非目标

- 不为用户、repository role、GitHub App 或 GitHub Actions 配置 ruleset bypass。
- 不拆分 Candidate tag 与最终 Release tag。
- 不允许使用 tag 后缀绕过 `v<MARKETING_VERSION>` 映射。
- 不允许复用失败发布的 App Version、build number、tag 或已签名资产。
- 不改变 Sparkle 签名、资格测试、Release 公开或 Production Feed 激活协议。

## 生命周期不变量

推送 `v<MARKETING_VERSION>` tag 是版本标识被占用的时间点。从该时刻开始：

- tag 必须永久指向原始 commit；
- tag 不得删除、移动、覆盖或重新创建；
- 对应 App Version 和 build number 永久视为已使用；
- 同一 tag 的 workflow 不得通过替换资产重新尝试发布；
- 后续尝试必须先在 `main` 提交更高且未使用的 `MARKETING_VERSION` 与严格递增的 `BUILD_NUMBER`，再创建匹配的新 tag。

`v*` tag ruleset 保持启用，继续禁止 update 与 deletion，并保持 bypass actor 列表为空。

## 失败状态机

### Tag 推送后、Draft Release 创建前失败

如果构建、测试、签名或 Candidate 准备在 Draft Release 创建前失败：

- 不存在需要清理的 Release；
- 保留失败 tag；
- App Version、build number 和 tag 均 burned；
- 修复后使用更高版本、递增 build 和新 tag 重新开始。

不得重新运行失败 tag 来生成新的签名资产或创建新的 Draft Release。

### Candidate Draft 创建后失败

如果 Candidate 准备完成，但本地资格测试失败或证据不足：

- Release Operator 删除不可见的 Draft Release；
- 删除命令不得包含 tag cleanup；
- tag 永久保留；
- App Version、build number 和 tag 均 burned；
- 修复后使用更高版本、递增 build 和新 tag 重新开始。

删除 Draft Release 是为了移除已失败的候选资产，不表示释放版本标识。

### 公开复验失败

`publish-update` 公开 Immutable Pre-release 后，如果固定公开 URL 下载、字节比较、checksum、Ed25519 验签或 GitHub Release integrity 验证失败：

- workflow 尝试仅删除 Release；
- workflow 不尝试删除 tag；
- Production Feed 不得推进；
- tag 永久保留；
- App Version、build number 和 tag 均 burned；
- 修复后使用更高版本、递增 build 和新 tag 重新开始。

如果自动删除 Release 失败，workflow 保持失败并要求 Release Operator 介入。Operator 只删除 Release，不删除 tag。清理失败不得转化为 Production Feed 激活。

### Production Feed 激活后失败

Production Feed compare-and-swap 成功后，既有 Activation Pending 和 Distribution Halt 规则保持不变：

- 不删除或修改 Release、tag 或资产；
- raw URL 缓存超时只进入 Activation Pending；
- 功能回归使用 Distribution Halt 或更高版本 repair update；
- tag 生命周期不受 feed 恢复操作影响。

## Workflow 修改

`.github/workflows/publish-update.yml` 的公开复验失败 trap 保留，但清理动作改为 Release-only：

- 使用 `gh release delete "$TAG" --yes`；
- 禁止 `--cleanup-tag`；
- 日志明确说明 Release 被删除、tag 被保留并 burned；
- 自动清理失败提示 operator 仅删除 Release；
- trap 继续返回原始复验失败状态。

`prepare-candidate.yml` 不增加自动清理。Candidate 资格测试发生在 workflow 结束后的受控真实 Mac 上，Draft Release 清理由 Release Operator 按手册执行。

## 手册修改

`docs/releasing.md` 明确区分三类失败：

1. Draft 创建前失败：无需清理 Release，保留 tag，提升版本后创建新 tag。
2. Candidate 资格失败：执行 `gh release delete <tag> --yes`，保留 tag，提升版本后创建新 tag。
3. 公开复验失败：workflow 只删除 Release；自动清理失败时 operator 执行相同的 Release-only 命令。

手册同时明确：

- 不运行 `git push --delete`；
- 不运行 `gh release delete --cleanup-tag`；
- 不移动或重新推送旧 tag；
- 新 tag 必须继续满足 `v<MARKETING_VERSION>`，因此需要新的 App Version，而不是添加 Candidate 或 retry 后缀；
- `BUILD_NUMBER` 必须严格递增。

## 测试策略

`Tests/ScriptTests/update_feed_tests.sh` 更新 workflow 契约：

- 公开复验失败路径必须包含 `gh release delete "$TAG" --yes`；
- 整个发布 workflow 禁止 `--cleanup-tag`；
- 整个发布 workflow 禁止 `git push --delete` 和其他 tag 删除命令；
- 激活阶段继续禁止删除 Release 或 tag；
- 发布手册必须包含永久保留失败 tag、创建更高版本新 tag 和 Release-only cleanup 的指导。

验证命令：

```bash
bash Tests/ScriptTests/update_feed_tests.sh
bash -n Tests/ScriptTests/update_feed_tests.sh
ruby -e 'require "yaml"; YAML.safe_load_file(".github/workflows/publish-update.yml", aliases: true)'
```

## 风险与控制

失败 tag 会永久累积，这是有意保留的审计记录。它增加 tag 列表噪声，但避免给个人或自动化提供可删除正式版本 tag 的宽权限。

仅删除公开失败 Release 会留下没有关联 Release 的 burned tag。发布手册与 Actions run 共同记录失败原因；tag 本身只证明该版本标识已被占用，不证明发布成功。Production Update 的有效性仍以经过公开复验并被已签名 Production Feed 引用为准。

如果未来 tag 数量或操作成本显著增加，应单独设计 Candidate tag 与最终 Release tag 的双生命周期协议；不得通过临时添加 ruleset bypass 绕过本设计。
