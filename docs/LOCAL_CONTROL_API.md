# DG-LAB 本地控制 API（macOS）

完整 macOS 原生界面见 [macos/DGLabConsole](../macos/DGLabConsole/README.md)。这里的 API 与 [iOS WebSocket Bridge](IOS_BRIDGE.md) 复用已有 Telegram Bot 会话，**不会启动额外的 Telegram 轮询器**。

## 网络和认证

服务在配置了 `IOS_BRIDGE_TOKEN`（至少 32 字符）后启用，默认绑定 **`127.0.0.1:8789`**。可通过 `DG_LOCAL_API_PORT` 修改端口，但不支持绑定到 LAN 或公网地址。

所有 `/v1/*` 路由必须提供 `Authorization: Bearer <IOS_BRIDGE_TOKEN>`。跨源浏览器 Origin 请求被拒绝；HTTP POST 还要求 `Content-Type: application/json`、最大 16 KiB，请求每秒限速 6 条，`session.stop` / `session.disconnect` 不受此普通限速。密钥属于**管理员权限**，不要交给 Telegram 投票成员。输入密钥应来自本地环境/Keychain，不要写在公开代码或仓库文档。

## 示例

以下命令先读取 macOS Keychain 中由本机管理员创建的桥接密钥。**请注意 Shell 环境变量可能被同一用户其他进程读取，不要截图或向外分享。**

```bash
export IOS_BRIDGE_TOKEN="$(security find-generic-password -s dglab-ios-bridge -w)"

# 读取已授权状态，不启动设备
curl -fsS -H "Authorization: Bearer $IOS_BRIDGE_TOKEN" \
  http://127.0.0.1:8789/v1/status

# 可用命令和范围
curl -fsS -H "Authorization: Bearer $IOS_BRIDGE_TOKEN" \
  http://127.0.0.1:8789/v1/capabilities

# 只创建草稿，无设备输出
curl -fsS -X POST http://127.0.0.1:8789/v1/command \
  -H "Authorization: Bearer $IOS_BRIDGE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"command":"session.create","payload":{"mode":"collaboration"}}'

# 紧急停止会话并尝试归零
curl -fsS -X POST http://127.0.0.1:8789/v1/command \
  -H "Authorization: Bearer $IOS_BRIDGE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"command":"session.stop","payload":{}}'
```

**不要在无设备现场准备的情况下调用以下命令**：

- `device.connect`：需要额外请求头 `X-DGLab-Confirm: connect`。
- `session.arm`：需要 `X-DGLab-Confirm: arm`，可能将 A/B 初始化为强度 1 并启动波形。

## 命令类别

| 类别 | 命令 | 输入 |
|---|---|---|
| 查询 | `status`, `device.status` | `{}` |
| 会话 | `session.create`, `session.arm`, `session.stop`, `session.disconnect`, `session.invite`, `session.join` | create 的 `mode=collaboration/voting/event` |
| 设备 | `device.connect` | 需要额外确认头 |
| 强度与波形 | `owner.delta`, `owner.waveform`, `vote.submit` | `channel=A/B`、`delta=±1/±3/±5`、`waveformId` |
| 自动提升 | `ramp.rate`, `ramp.maxIncrease`, `ramp.toggle` | `channel=A/B`、`rateSeconds=1..60`、`maxIncrease=1..33` |
| 音频 | `audio.volume`, `audio.beat`, `audio.off`, `audio.target`, `audio.range` | `target=A/B/both`，`minHz/maxHz=1..100` |
| Telegram 活动 | `group.bind`, `event.queue`, `event.queue.leave`, `event.random`, `event.pool` | `groupId`（负整数）、`preset=all/gentle/strength/waveform` |

返回 JSON：成功 `{"ok":true,"state":{...}}`，失败 `{"ok":false,"error":"..."}`。控制错误多为 HTTP `409`；无密钥 `401`；缺乏启动/连接确认 `403`；请求过频 `429`。

系统不提供任意 Bash / shell / 文件管理命令。停止 API 成功不等于物理设备一定已断电；当 BLE 断连时必须有外部硬件停止手段。
