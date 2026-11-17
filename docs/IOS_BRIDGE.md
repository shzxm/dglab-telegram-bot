# iOS / Telegram 控制桥接

## 两种模式

1. **iPhone 蓝牙主机**：MacBook Pro 上的 Telegram Bot 仍管理群聊、邀请、投票、活动和身份校验，`DG_DEVICE_MODE=ios` 时将设备命令转给 iPhone 的 CoreBluetooth 驱动。每次启动会话都要在 iPhone 上现场确认。设备不能同时与 MBP BLE 和 iPhone BLE 连接。
2. **远程操作 Bot**：`DG_DEVICE_MODE=ble` 时，MBP 继续连接实体设备，iPhone 只是控制面板；Telegram 仍由 MBP 唯一进程轮询，App 不直接读取 Bot Token 或轮询消息。

桥接服务作为同一个 Bot Node 进程的可选 WebSocket 端点。默认仅监听 `127.0.0.1:8788`，需要从手机连接时，应**显式**把 `IOS_BRIDGE_HOST` 配成 MBP 的内网地址，并限制可信网络；跨互联网访问必须通过 HTTPS/WSS 代理与访问控制，绝不要直接公网暴露 `8788`。

## 配置

- `IOS_BRIDGE_TOKEN`：独立随机高熵密钥，至少 32 字符，不是 Telegram Bot Token。建议 macOS Keychain 存储。
- `IOS_BRIDGE_HOST`：默认 `127.0.0.1`；仅在可信 LAN 内开启内网 IP 绑定。
- `IOS_BRIDGE_PORT`：默认 8788。
- `DG_DEVICE_MODE`：`mock`、`ble`、`ios`。只有确实要让手机取代 Mac 蓝牙时才设置为 `ios`。

正式部署建议用 Keychain/启动包装脚本将 `IOS_BRIDGE_TOKEN` 提供给子进程，不得写入公开 plist。iPhone 设置页输入 `ws://192.168.x.x:8788` 和**桥接密钥**，将密钥存入设备专属 Keychain。与现有 Telegram Bot Token 严格隔离。

### 安全约束

- 新建会话/授权必须由管理员操作；iPhone 作为主机时，还需要手机端本地的二次批准。
- 每次连接时执行初始归零指令，停止/失联时双通道停止。会话到期、应用进入后台和捕获异常时尝试归零。
- iOS 后台不能可靠保证 100 ms 的 BLE 波形指令，App 会在离开前台时尝试安全停止。**实体设备仍必须保留独立紧急断电/停止手段。**
- 桥接密钥不能放入应用源码、README、Git 或聊天记录。桥接独立采用 WebSocket Bearer 鉴权和命令频率控制。
- 当前客户端和桥接协议经过模拟测试，但仍需要签名安装 iPhone 后的 BLE/后台/网络真机验收。

### 设备/操作命令

`session.create`、`session.arm`、`session.stop`、`session.disconnect`、`session.invite`、`session.join`、`owner.delta`、`owner.waveform`、`ramp.toggle`、`ramp.rate`、`audio.volume`、`audio.beat`、`audio.range`、`group.bind`、`vote.submit`、`event.queue`、`event.queue.leave`、`event.random`、`event.pool`、`status`。

手机主机需要处理 `device.connect`（需本地授权）、`device.zero`、`device.strength`、`device.waveform`、`device.modulation`、`device.emergency`、`device.disconnect`。另外可以通过 `audio.monitor.start/stop` 接收 MBP 系统音频的 RMS 实时数值。

## 安装与验收

在 MacBook Pro 上先确认 `/state` 活动会话为 false 且 A/B=0，备份文件后安装依赖并 `npm run typecheck && npm test && npm run build`。只有完成这些检查后才重启 LaunchAgent。先用 `curl http://127.0.0.1:8788/health` 验证监听，再测试桥接身份验证。**不要在实体输出过程中切换 `DG_DEVICE_MODE` 或重启。**


## iOS v1.1 增量字段和交互

`state` 快照包含 `rampA`、`rampB`、`rampRateA` / `rampRateB`、`rampMaxA` / `rampMaxB`、`rampDoneA` / `rampDoneB`。App 滑杆松手后提交：

```json
{"type":"command","id":"example-ramp","command":"ramp.rate","payload":{"channel":"A","rateSeconds":12}}
```

```json
{"type":"command","id":"example-limit","command":"ramp.maxIncrease","payload":{"channel":"A","maxIncrease":10}}
```

动态调整间隔不会重置累计次数；完成指定自动 +1 次数或先达到通道强度上限后自动停止。`audio.range` 支持任意 `1 <= minHz <= maxHz <= 100` 的整数端点，例如 5–88 Hz，固定频率使用相等端点。

**协作角色对照**见 [ARCHITECTURE.md](ARCHITECTURE.md)，**安全边界**见 [SECURITY.md](SECURITY.md)，**iOS App** 见 <https://github.com/shzxm/dglab-ios>。


## macOS 原生 GUI / REST API 的区别

macOS 本机另有 [DG-LAB Console](../macos/DGLabConsole/README.md)，使用 **127.0.0.1:8789** 的 HTTP Bearer API（[REST 文档](LOCAL_CONTROL_API.md)），不会对外开放该端口。iOS App 则继续使用本项目独立的 WebSocket 桥接端口（默认 8788）。**两套接口都使用同一份高熵桥接密钥和同一个 ControlSession，但协议和默认监听地址不同**；不会启动两个 Telegram Bot 实例。
