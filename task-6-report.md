# Task 6 Report

修复提交：`a70cd4517210a701189a0f936facf4ed9762c5a2`

最终修复：

1. `swap-expected` 在最终 rename 前重新确认目标 app 的 device/inode 与最初源 app 一致；夹具会在 staged 验证后替换源 app，确认新 inode 和完整树保持不变。
2. 发布 helper 在成功 rename 后提供仅测试使用的暂停点。`package_release.sh` 会在调用 helper 前登记每个 staged artifact 的 device/inode；即使整个进程组在该暂停点收到 `TERM`，EXIT cleanup 也只删除该最终 inode，不影响既有文件。

验证：

- `bash Tests/ScriptTests/package_verification_tests.sh`
- `/usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=13.0 script/helpers/atomic_swap.c -o /tmp/codex-radar-atomic-swap`
- `bash -n script/package_release.sh script/sign_app.sh Tests/ScriptTests/package_verification_tests.sh`
- `swift test`

脚本夹具验证了可移植 ZIP checksum、解压后的 app、嵌套签名，以及 post-rename 的 exit 130、精确 inode 回滚、隐藏 stage 清理、既有 artifact 集不变和锁释放后的重试。
