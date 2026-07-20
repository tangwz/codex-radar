# 自动更新发布操作手册

当前发布链使用 Sparkle Ed25519 更新签名和 ad-hoc 应用签名。它不提供 Apple Developer ID、公证或 Gatekeeper 身份保证；首次安装仍属于独立的引导信任边界。

## 一次性密钥迁移

仅在受控的 operator Mac 上执行迁移。先确认 Keychain 中已有公钥与 `config/update.env` 的 `SPARKLE_PUBLIC_ED_KEY` 完全一致：

```bash
./bin/generate_keys --account com.terence.codex-radar -p
```

使用仅当前用户可读的传输文件导出私钥，通过标准输入写入受保护的 `release` Environment secret，并在同一次受控操作中创建 encrypted offline backup：

```bash
(
  umask 077
  transfer_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-radar-ed25519.XXXXXX")"
  transfer_file="$transfer_dir/private-key"
  cleanup() {
    rm -f "$transfer_file"
    rmdir "$transfer_dir" 2>/dev/null || true
  }
  trap cleanup EXIT HUP INT TERM

  ./bin/generate_keys --account com.terence.codex-radar -x "$transfer_file"
  chmod 600 "$transfer_file"
  gh secret set SPARKLE_ED_PRIVATE_KEY --env release <"$transfer_file"
  age -p -o codex-radar-ed25519.age "$transfer_file"
)
```

把加密备份移到离线介质，并从日常工作目录移除。`trap` 清理是 best-effort：runner 崩溃、宿主机异常或强制终止时，脚本无法承诺执行清理，因此这一步只能在受控、一次性的本机环境完成。私钥不得进入命令行参数、仓库、缓存、日志或 Artifact。

## GitHub 配置

- `release` Environment 仅允许 `v*` tag，并在签名 job 启动前要求 operator 审批。
- 当前单人发布阶段允许发起者自审；增加第二位可信 operator 后，启用 required reviewer 并禁止自审。
- 为 `main` 启用 review、CI、CODEOWNERS 和分支保护。
- 在首次公开自动更新前启用 Immutable Releases。

## 准备 Candidate

1. 更新 `version.env`，确保 `MARKETING_VERSION` 未使用过，`BUILD_NUMBER` 严格递增。
2. 从 `main` 对目标提交创建 `v<MARKETING_VERSION>` tag 并推送。
3. `prepare-candidate` 先在无 secret 的只读 job 中测试并构建 Universal 2 ZIP；只有 tag 路径会进入 `release` Environment。
4. workflow 完成后确认 Release 仍为 Draft，并下载保留七天的 qualification Artifact。
5. 对后续版本，在受控真实 Mac 上，以真实上一 Production Update 运行 `script/qualify_update.sh` 完成端到端更新测试。

bootstrap 0.1.0 (1) 是例外：它没有上一 Production Update，不能也不应运行 `script/qualify_update.sh`。该版本执行首装引导验收，包括固定 ZIP/checksum/manifest 复验、应用结构与 ad-hoc 签名复验、手动安装、启动和更新设置检查；它建立首个手动安装基线。完整的 Sparkle 端到端升级资格测试从下一 Candidate 开始，使用已安装的 0.1.0 (1) 作为上一 Production Update。

bootstrap 的公开 Release、真实 Ed25519 私钥签名 `appcast.xml` 和真实 Mac 首装验收都是外部门禁。在这些门禁完成之前，不得宣称自动更新已可用。仓库根目录的 `appcast.xml` 只能由真实签名的 bootstrap publication workflow 生成并激活；禁止手写、使用测试密钥签名或提交占位 feed。

手动触发 `prepare-candidate` 只执行无 secret dry run：它生成构建 Artifact，但不创建 Release，也不读取发布私钥。

## 公开与激活 Production Update

本地资格测试通过后，Release Operator 手动触发 `Publish Update`，且只填写已经通过测试的 Draft tag。触发记录就是当次真实 Mac 资格测试通过的发布声明。此 workflow 不读取 Ed25519 私钥，也不重新生成、编辑或签名任何资产。

workflow 会重新下载 Draft 的四个资产，独立复验 tag、版本、commit、checksum、manifest、最终 `Info.plist`、signed appcast 和 ZIP 的 Ed25519 archive signature。验证通过后，它把 Release 公开为 Immutable Pre-release，再从版本固定的公开 URL 重新下载相同资产并执行同一组验证以及 GitHub Release integrity 验证。首次公开自动更新前必须已经在仓库设置中启用 Immutable Releases。

公开资产复验失败时，workflow 会尝试删除刚公开的 Release 和 tag；对应的 App Version、build number 和 tag 随即 burned，不能重新使用。如果自动清理失败，停止发布并由 Release Operator 介入，Production Feed 不得推进。

公开复验通过后，workflow 读取 `main/appcast.xml` 的精确字节和当前 blob SHA。只有当前字节仍与预期上一份 signed feed 完全一致时，才通过 GitHub Contents API compare-and-swap 写入候选 feed；HTTP 409、422 或任何第三种字节状态都立即终止，禁止强制覆盖。bootstrap `0.1.0 (1)` 是唯一允许在 feed 返回 404 时无 blob SHA 创建的版本，并且写入前会再次确认没有其他 Release 历史且 feed 仍不存在。

CAS 成功后，公开 Release 和 tag 永远不得自动删除或回滚。workflow 会有限次轮询固定 raw URL：旧 feed 字节只表示缓存尚未收敛；候选精确字节表示发布完成；任何其他字节必须由 Release Operator 调查。轮询超时进入 `Activation Pending`，不代表发布失败，也不允许回滚。此时只在原 workflow run 中选择重新运行失败的 job，使它确认仓库 blob 已经是同一候选并继续只读复验 raw URL；不要新建一次 workflow dispatch，也不要重新写 feed。

## 失败与密钥事件

Candidate 资格测试失败后，由 operator 删除不可见 Draft Release 和 tag。对应的 App Version、build number 和 tag 均视为 burned；修复必须使用更高且从未使用的标识重新发布，不得替换同名资产或复用版本。

私钥丢失、完整性无法确认或疑似泄露时，立即停止自动更新发布。保留既有公开 Release 供审计并发布安全公告；恢复只能生成新 key、发布新的手动 bootstrap，并要求用户重新安装，禁止用旧 key 自动换钥或降级到未签名更新。

## Distribution Halt

Distribution Halt 用于最新 Production Feed 指向的版本存在问题、但 Ed25519 更新私钥仍可信的场景。它只把 `main/appcast.xml` 原子恢复为历史提交中仍由同一可信 key 签名的上一份 Production Feed，不删除或修改任何 Release、tag 或资产。它与密钥事件不同：私钥丢失、完整性不明或疑似泄露时不得运行此命令，必须按“失败与密钥事件”停止更新供应链并重新 bootstrap。

先从审计记录中找到包含上一份已公开 signed feed 的完整 40 位 commit SHA，然后在受控 operator Mac 上运行：

```bash
script/halt_distribution.sh --previous-commit 0123456789abcdef0123456789abcdef01234567
```

命令使用已认证的 operator `gh` session，通过 GitHub Contents API 读取 `main/appcast.xml` 的当前精确字节和 blob SHA，并从指定 commit 读取上一份精确字节。任何写入前，它会用固定在 `config/update.env` 中的 Sparkle Ed25519 公钥验证两份 feed，要求二者都使用版本固定资产 URL、最低系统版本一致，且 previous build 严格低于 current build。随后命令打印两份 feed 的版本、build 和 SHA-256；operator 必须输入由已验签 current feed 得出的当前 tag，完全匹配后才继续。

写入使用当前 blob SHA 对 `main/appcast.xml` 执行 compare-and-swap，并把上一份 signed feed 的精确字节作为内容。HTTP 409 或 422 表示 CAS 冲突，命令立即停止且绝不强制覆盖。PUT 后命令通过 Contents API 独立复读仓库 blob，要求字节完全等于 previous feed；然后有限次轮询固定 raw URL。raw 返回 current 精确字节时只等待缓存传播，返回 previous 精确字节才报告成功，任何第三种字节立即硬失败。轮询超时只报告 `Distribution Halt Pending`，不得宣称完成，也不得删除 Release 或 tag。

如果 PUT 已在 GitHub 生效但响应丢失，或命令在写入后进入 `Distribution Halt Pending`，使用同一个 `--previous-commit` 原样重跑。current 与 previous 精确字节相等本身不足以证明 Distribution Halt 已经发生：命令还会通过 authenticated `repos/tangwz/codex-radar/commits?sha=main&path=appcast.xml&per_page=1` 查询最近一次修改 `appcast.xml` 的 commit，严格读取它的第一个 parent SHA，并从该 parent 获取 intervening Production Feed。

只有 current、previous 和 intervening Production Feed 都由同一固定公钥验签，使用版本固定 URL 和相同最低系统版本，intervening bytes 与 halted bytes 不同，且 intervening build 严格高于 halted build 时，verifier 才返回 `already-halted`。commit history 读取失败、结构或 SHA 非法、缺少 parent、parent feed 无效或 build 方向错误都会硬失败；判定不依赖 commit message。进入 `already-halted` 后，命令不再要求 tag 确认，也不重复 PUT，只复读 repository blob 并继续轮询 fixed raw URL。raw URL 返回已验签的 intervening 精确字节时可以等待缓存传播，返回 previous 精确字节才完成，任何第三种字节立即硬失败。不要改用另一个 commit 猜测恢复状态。

Distribution Halt 不会降级已经完成更新的安装。`Guarantee: already-upgraded installations are not downgraded.` Sparkle 不会把已经安装的新 build 降级到旧 build。必须修复已升级用户时，使用更高且从未使用的 App Version/build 发布 repair update，禁止复用或替换既有版本。

## 真实 Mac 验收记录

每个 bootstrap 首装或后续 Candidate 端到端资格测试都保存一份记录。开始时状态必须是 Pending，只有所有证据复核完毕后才能改为 Passed；失败或证据缺失时保持 Pending。

```text
Acceptance status: Pending | Passed
Date (UTC):
Operator:
Mac model:
macOS version:
Architecture: arm64 | x86_64
Release tag:
App version and build:
Immutable ZIP URL:
ZIP SHA-256:
Checksum asset URL:
Manifest SHA-256:
Feed SHA-256:
Install location: /Applications | ~/Applications
First-install path: Finder Open | Privacy & Security Open Anyway
Launch result:
Update settings result:
Previous installed version and build (non-bootstrap only):
End-to-end Sparkle update result (non-bootstrap only):
Read-only location result:
App Translocation result:
Failure-injection results:
Evidence links:
Notes:
```
