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
- 不改变 Sparkle 签名、资格测试、Release 公开或 Production Feed compare-and-swap 协议；只把 bootstrap 资格从固定版本改为可验证的仓库状态。

## 生命周期不变量

推送 `v<MARKETING_VERSION>` tag 是版本标识被占用的时间点。从该时刻开始：

- tag 必须永久指向原始 commit；
- tag 不得删除、移动、覆盖或重新创建；
- 对应 App Version 和 build number 永久视为已使用；
- 同一 tag 的 workflow 不得通过替换资产重新尝试发布；
- `prepare-candidate` 的 tag push 路径只允许第一次 workflow attempt，rerun 不得进入签名 Environment 或创建 Draft Release；
- 所有 Candidate 都必须在签名前与其他受保护 `v*` tag identity 比较，不得只依赖当前 Production Feed；
- 签名前 identity 校验成功是 Candidate 的 reservation point；之后创建的 tag 不追溯性地使该 Candidate 失效；
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

如果失败发生在首个 Production Feed 激活前，固定的首发版本也已经 burned。新的更高 App Version、递增 build number 和新 tag 在 Production Feed 仍不存在、失败 Release 已删除且 GitHub Release 历史为空时继续作为 bootstrap；bootstrap 资格不得依赖 `0.1.0 (1)` 常量。

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

`prepare-candidate.yml` 不增加自动清理。它在无 secret 的验证步骤拒绝 tag push rerun，并在 `sign-candidate` job 条件中要求 `github.run_attempt == 1`，避免 rerun 进入发布 Environment。Candidate 资格测试发生在 workflow 结束后的受控真实 Mac 上，Draft Release 清理由 Release Operator 按手册执行。

`prepare-candidate.yml` 与 `publish-update.yml` 共用 `update-${{ github.repository }}` concurrency group，设置 `cancel-in-progress: false` 与 `queue: max`。不同 tag 的 workflow 不得并行进入签名、公开或 feed 激活阶段，后续 run 也不得淘汰已有 pending run。

所有 Candidate 的 release identity 校验遵循：

- Candidate 的版本与 build 仍须通过通用格式和一致性校验；
- Candidate 的 App Version 与 build number 必须分别严格高于所有其他受保护 `v*` tag 所指向提交中的 `version.env`；
- identity 校验在签名前执行并建立 reservation；
- tag 缺少合法 `version.env` 或 identity 不满足严格递增时均 fail closed。

bootstrap 额外以状态而不是固定版本判定资格：

- Production Feed 必须不存在；
- 签名前 GitHub Release 历史必须为空；
- 公开后和 CAS 写入前，除当前 Candidate 外不得存在其他 Release；
- 写入前必须再次确认 Production Feed 仍返回 404。

Actions concurrency 只能串行化 workflow，不能原子化外部 tag push 与 Contents API CAS。因此公开与激活阶段不得通过再次获取 tag 来追溯性地撤销已签名 Candidate；后续 tag 在自己的签名前门禁中相对于所有已有 tag 校验。CAS 成功后仍禁止删除或回滚 Release、tag 或资产。

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
- 强制 refspec `git push origin +:refs/tags/<tag>` 也必须被识别为 tag 删除；
- Candidate tag push rerun 必须在签名和 Draft Release 创建前失败；
- 首个 bootstrap tag burned 后，更高版本和 build 的新 tag 在 feed 与 Release 历史均为空时仍可 bootstrap；
- bootstrap 与普通 Candidate 都必须在签名前与全部其他 `v*` tag identity 比较并建立 identity reservation；
- 两个发布 workflow 必须使用带 `queue: max` 的仓库级共享 concurrency；
- 激活阶段继续禁止删除 Release 或 tag；
- 发布手册必须包含永久保留失败 tag、创建更高版本新 tag 和 Release-only cleanup 的指导。

验证命令：

```bash
bash Tests/ScriptTests/update_feed_tests.sh
bash -n Tests/ScriptTests/update_feed_tests.sh
ruby -e 'require "yaml"; YAML.safe_load(File.read(".github/workflows/prepare-candidate.yml"), aliases: true); YAML.safe_load(File.read(".github/workflows/publish-update.yml"), aliases: true)'
```

## 风险与控制

失败 tag 会永久累积，这是有意保留的审计记录。它增加 tag 列表噪声，但避免给个人或自动化提供可删除正式版本 tag 的宽权限。

仅删除公开失败 Release 会留下没有关联 Release 的 burned tag。发布手册与 Actions run 共同记录失败原因；tag 本身只证明该版本标识已被占用，不证明发布成功。Production Update 的有效性仍以经过公开复验并被已签名 Production Feed 引用为准。

如果未来 tag 数量或操作成本显著增加，应单独设计 Candidate tag 与最终 Release tag 的双生命周期协议；不得通过临时添加 ruleset bypass 绕过本设计。
