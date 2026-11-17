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

macOS GUI 不持有 BotFather Token；仅从 Keychain 读取或保存单独的 `IOS_BRIDGE_TOKEN`，经 `http://127.0.0.1:8789` 调用带 Bearer 的本地控制 API。API 固定只监听回环，不支持公开地址；禁止跨源 Origin 请求、过滤命令白名单、限制每秒调用次数。调用 `device.connect` / `session.arm` 时必须额外带明确确认头，GUI 提供现场确认框。

GUI 的 LaunchAgent 重启/停止按钮会现场重新读取 API 状态，仅在会话 inactive 且设备与会话两套 A/B 强度都为 0 时执行；无法获取状态时拒绝操作。即便软件显示已归零，也不能代替实体硬件安全停止。
