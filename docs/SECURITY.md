# Security / 安全说明

## 配置和隐私

- 使用 `config.example.json` / `.env.example` 演示格式，但不在公开仓库上传真正的 `config.json`、`.env`、Telegram Bot Token、`IOS_BRIDGE_TOKEN`、密钥证书、Mac 用户路径、私人聊天/群 ID、家庭网络地址。
- `TG_BOT_TOKEN` 只存在于 Mac。`IOS_BRIDGE_TOKEN` 是至少 32 个字符的独立随机密钥，只给受信任的 iOS App 管理端，不共享给 Telegram 普通参与者。
- WebSocket 默认监听 `127.0.0.1`，仅在明确配置可信 LAN 主机地址后允许手机连接。公网访问需要 WSS/受控反代/认证网关；仅依赖裸露端口和 Bearer 密钥不够。
- `/state` 和 `/obs` 可能包含会话强度、参与情况，默认不开放到公网。不要公开分享直播中含身份信息的截图。

## 设备风险

- 133 是软件可配置的最高强度档位，不是人体安全阈值。
- 声音响应 + 自动提升可同时启用，强度和节奏变化的叠加效果不可仅凭代码推断。
- 停止/超时会尝试向设备发送归零；蓝牙中断、App 被系统挂起或硬件失联可能阻止停止数据包送达。必须有独立可立即使用的硬件断开方式。
- 模拟器、Mock 设备和类型检查通过**不等于**实测 BLE 安全验证。

## 负责任披露

对凭证泄露、未经授权控制、停止失效等安全问题，请通过 GitHub 仓库的私密漏洞披露渠道（如已开启）或其他私密渠道联系维护者。不要在公开 Issue 附上真实密钥、聊天记录或设备位置。


## macOS GUI / 本地 API

macOS GUI 使用 App 私有目录中的 `IOS_BRIDGE_TOKEN`，可选的 Telegram Bot Token 也只保存在同一私有配置文件，不调用 Keychain；经 `http://127.0.0.1:8789` 调用带 Bearer 的本地控制 API。API 固定只监听回环，不支持公开地址；禁止跨源 Origin 请求、过滤命令白名单、限制每秒调用次数。调用 `device.connect` / `session.arm` 时必须额外带明确确认头，GUI 提供现场确认框。

GUI 安全停止/退出时会经本地 API 依次停止音频、自动提升、会话并尝试归零、断开设备；只有回读确认停止并断开后才结束内置 Node 进程，无法获取状态时拒绝退出。即便软件显示已归零，也不能代替实体硬件安全停止。


## 自包含 Mac App 与 TCC 授权

原生 App 包含其自己的 Node 子进程、生产依赖及音频辅助程序；只有用户点击「启动内置引擎」才运行，并拒绝在旧服务占用 API/OBS 端口时启动第二个控制器。初始模式 `mock`。用户的高熵桥接密钥和 Bot Token 保存在本地 App Support 目录的私有 `0600` 文件中，不编入程序或日志；导入旧版非敏感配置需要用户明确点击，旧钥匙串密钥不自动读取。

系统权限由 macOS TCC 管理。蓝牙使用 CoreBluetooth 权限接口；麦克风使用 AVFoundation；屏幕与系统音频使用 CoreGraphics/ScreenCaptureKit；通知使用 UserNotifications。局域网和已拒绝的权限提供系统设置入口。**任何一个按钮都不能代替用户批准或保证音频子进程的 TCC 归属。**

必须牢记，用户终止进程、BLE 断开或系统挂起时，最后一条零输出指令不一定成功送达设备；不允许把 App 退出防护宣传为物理急停替代方案。


## macOS v1.1.1 安全停机更新

用户主动关闭 App、关闭最后一个窗口或点击内置引擎的「停止并断开所有控制」时，SwiftUI 会以持有鉴权的本地 API 发送 `session.disconnect`，等待控制核心停止自动提升、系统音频辅助、会话输出并断开设备，随后回读设备/会话状态确认未激活、A/B 均为 0 且驱动报告已断开，才发送 SIGTERM 并等待 App 内的 Node 子进程退出。仅在已获安全确认、但 Node 仍不响应时才会在延迟后强制终结 Node。

若 API 失联、等待超时或安全状态未知，将保留 App/进程并报告错误，**不虚构“已断电”**。本保护不能替代硬件急停或对蓝牙丢包后实际输出状态的现场验证。


## v1.2.0 本地私有密钥存储（替代 Keychain）

为避免 macOS 钥匙串访问弹窗，原生 macOS GUI 不再调用 `SecItem*` 等 Keychain API。设备 API / iOS 桥接共享密钥和可选 Telegram Bot Token 保存在当前用户的 `~/Library/Application Support/DG-LAB Console/credentials.json`（父目录 `0700`，文件 `0600`），通过带 `O_EXCL|O_NOFOLLOW` 的临时 `0600` 文件加 `fsync`、原子 `rename` 写入。已有凭证文件损坏时拒绝自动覆盖。安装包中不附带密钥，且不会自动读取旧 Keychain 项目。

**权衡：此实现省去了 Keychain 的 TCC/访问确认，但比 Keychain 弱**。任何能够以同一用户身份读取本地文件的程序都有可能读取这些明文密钥。因此不要赋予未知软件当前用户权限；如怀疑凭证泄露，旋转桥接密钥并让客户端同步，必要时通过 BotFather 撤销并重新颁发 Telegram Token。

操作与嵌入引擎 stdout/stderr 使用有界 `0600` 日志文件；写入时和导出时多次正则遮盖 Bearer、Telegram Token、常见敏感字段与当前存储密钥。导出的 `.txt` 使用用户选择的位置，不能保证目标目录私有或额外加密。分享前需再次人工检查隐私信息。
