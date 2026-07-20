# 自动更新发布操作手册

当前发布链使用 Sparkle Ed25519 更新签名和 ad-hoc 应用签名。它不提供 Apple Developer ID、公证或 Gatekeeper 身份保证；首次安装仍属于独立的引导信任边界。

## 一次性密钥迁移

仅在受控的 operator Mac 上执行迁移。先确认 Keychain 中已有公钥与 `config/update.env` 的 `SPARKLE_PUBLIC_ED_KEY` 完全一致：

```bash
./bin/generate_keys --account com.terence.codex-radar -p
```

使用仅当前用户可读的传输文件导出私钥，通过标准输入写入受保护的 `release` Environment secret，并在同一次受控操作中创建 encrypted offline backup：

```bash
transfer_file="$(mktemp "${TMPDIR:-/tmp}/codex-radar-ed25519.XXXXXX")"
chmod 600 "$transfer_file"
cleanup() {
  rm -f "$transfer_file"
}
trap cleanup EXIT HUP INT TERM

./bin/generate_keys --account com.terence.codex-radar -x "$transfer_file"
gh secret set SPARKLE_ED_PRIVATE_KEY --env release <"$transfer_file"
age -p -o codex-radar-ed25519.age "$transfer_file"
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

手动触发 `prepare-candidate` 只执行无 secret dry run：它生成构建 Artifact，但不创建 Release，也不读取发布私钥。

## 失败与密钥事件

Candidate 资格测试失败后，由 operator 删除不可见 Draft Release 和 tag。对应的 App Version、build number 和 tag 均视为 burned；修复必须使用更高且从未使用的标识重新发布，不得替换同名资产或复用版本。

私钥丢失、完整性无法确认或疑似泄露时，立即停止自动更新发布。保留既有公开 Release 供审计并发布安全公告；恢复只能生成新 key、发布新的手动 bootstrap，并要求用户重新安装，禁止用旧 key 自动换钥或降级到未签名更新。
