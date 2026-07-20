# Task 8 Report

补充本地更新资格校验的安全回归夹具，并修复一个复制期间的 TOCTOU 缺口。

完成内容：

1. 资格校验在复制上一版应用前后绑定根目录的 device/inode，拒绝同内容目录替换。
2. 夹具覆盖有效但字节不同的当前 Production Feed、逃逸与内部 symlink、复制时变更和替换源应用、服务端发布端口后退出，以及资格 bundle 在服务就绪后的源文件变更仍由私有快照提供内容。
3. 夹具逐项验证安装后版本、更新 URL、公钥与五个布尔更新键；所有 bundle 预检失败均断言 runner 和 CLI 未被调用。
4. INT 与 TERM 分别向测试副本记录的 harness PID 发送，断言记录的服务 PID 已退出，避免向测试父进程发送信号。

验证：

- `bash Tests/ScriptTests/update_feed_tests.sh`
- `bash -n script/qualify_update.sh Tests/ScriptTests/update_feed_tests.sh`
- `git diff --check`
