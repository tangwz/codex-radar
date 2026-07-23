# Codex Radar

Codex Radar 是一个以菜单栏为主要入口的 macOS 应用，用于查看 Codex reset 状态与本地 token 用量，并管理应用偏好。

## Language

**Menu Bar Panel**:
点击菜单栏图标后出现的紧凑状态与操作面板。
_Avoid_: Popup, 弹窗

**Settings Window**:
承载 Dashboard、Settings 和 About 三个同级页面的独立应用窗口。
_Avoid_: Preferences Window, Dashboard Window

**Dashboard**:
展示 Codex reset 状态和本地 token 用量的只读页面。
_Avoid_: Home, Overview

**Settings**:
管理语言与外观，并说明 reset 提醒行为的页面。
_Avoid_: General, General Settings

**About**:
展示应用身份、版本、外部链接和版权信息的页面。
_Avoid_: Info

**App Version**:
应用包中的发布版本与构建号。打包脚本是唯一写入来源，应用界面只读取生成后的 `Info.plist`；首个版本为 `0.1.0 (1)`。
_Avoid_: UI Version, Runtime Version Constant

**Candidate Release**:
资产已上传到 GitHub Draft Release、但尚未通过生产资格检查的版本。Candidate Release 对普通用户不可见；资格失败时删除 Draft Release 和 tag，并永久作废对应版本标识。
_Avoid_: Stable Release, Pending Update

**Production Update**:
已经通过生产资格检查并写入生产 appcast、可被现有安装发现的版本。是否经过 Apple 公证是独立属性，不决定其 Production Update 身份。
_Avoid_: Stable Release, Public Release

**Activation Pending**:
候选 appcast 已通过 compare-and-swap 写入仓库，但 Production Feed 尚未返回候选精确字节的暂态。该状态只允许幂等复验，不回滚 feed、不删除 Release，也不宣布发布完成。
_Avoid_: Failed Release, Rolled Back Update

**Distribution Halt**:
Production Update 出现严重功能回归后，通过 compare-and-swap 恢复上一份已验证 signed appcast，停止尚未升级的客户端继续发现问题版本。它不降级已经安装该版本的客户端，也不删除 Immutable Release。
_Avoid_: Client Rollback, Release Deletion

**Production Feed**:
固化在已发布应用中的 GitHub raw `main/appcast.xml` URL。该 URL 是长期兼容性契约；仓库迁移或重命名后仍须为旧客户端保留有效的迁移 feed。
_Avoid_: Latest Release URL, Temporary Feed

**Update Trust Chain**:
由已安装应用中固化的 Ed25519 公钥与受保护私钥连接起来的更新信任关系。私钥丢失、完整性无法确认或疑似泄露时，该信任链永久终止，只能通过新的手动 bootstrap 建立新链。
_Avoid_: Code Signing Identity, Recoverable Secret

**Release Operator**:
被信任去批准 Candidate Release 签名、执行真实 Mac 资格测试并手动触发公开发布的维护者。当前采用单人治理，Production Update 在公开资产复验成功后自动激活。
_Avoid_: Reviewer, Publisher
