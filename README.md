# DG-LAB Telegram Bot

这是一个运行在 macOS 上的 Telegram 控制器：Telegram Bot 接收按钮操作，Mac 通过蓝牙连接 DG-LAB 2 代设备。项目默认使用安全的模拟设备，不会连接蓝牙；只有明确配置 `deviceMode: "ble"` 后才会访问真实设备。

## 功能概览

- 管理员模式：管理员单人直接控制，其他成员只能查看同一控制面板和状态变化。
- 投票模式：成员分别为 A/B 强度和 A/B 波形投票，固定 5 秒统计，按各类别最高票动作执行。
- A/B 强度按钮：`+1`、`+3`、`+5`、`-1`、`-3`、`-5`。
- 强度上限：133；每位用户最近 1 秒最多操作 3 次。
- 会话时长：默认 9999 秒；管理员可随时停止、撤销并归零或断开设备。
- 波形：内置导入的 6 组波形，可分别用于 A、B；波形投票生效后持续循环，直到切换或停止。
- 自动提升：管理员专属，A/B 同步提升，最长 30 秒，可选每 3/5/7/11/13 秒一次。
- 安全保护：启动时 A/B 归零；停止、断开、过期、BLE 写入失败时执行安全归零。

## 工作流程

```text
Telegram 按钮
    ↓
权限检查 / 管理员模式或投票模式
    ↓
会话限幅、速率限制、5 秒投票结算
    ↓
Mac BLE 适配器
    ↓
DG-LAB ESTIM01（DG-LAB 2 代）
```

项目当前使用 Mac 直连 BLE，不依赖 DgLabUnlocker 的 WebSocket 服务。DgLabUnlocker RPC 文档中的强度限制规则仍可作为协议参考：超过被控方限制的请求会被忽略。

## 环境要求

- macOS，已登录桌面用户
- Node.js 20 或更高版本
- npm
- DG-LAB 2 代设备
- Telegram Bot Token
- 允许机器人加入的 Telegram 群（多人投票时需要）；如果群禁止机器人，可使用管理员私信模式

## 获取代码

```bash
git clone https://github.com/shzxm/dglab-telegram-bot.git
cd dglab-telegram-bot
npm install
```

## 创建 Telegram Bot

1. 在 Telegram 打开 `@BotFather`。
2. 使用 `/newbot` 创建机器人并保存 Token。
3. 不要把 Token 写入 Git、截图、日志或聊天记录。
4. 如果 Token 曾经泄露，先在 BotFather 撤销并重新生成。

## 配置

复制配置模板：

```bash
cp config.example.json config.json
```

编辑 `config.json`：

```json
{
  "telegramToken": "REPLACE_WITH_BOTFATHER_TOKEN",
  "ownerUserId": 123456789,
  "allowedChatId": -1001234567890,
  "deviceMode": "mock",
  "strengthLimit": 133,
  "sessionDurationSeconds": 9999,
  "voteWindowSeconds": 5,
  "actionWindowMs": 1000,
  "actionsPerWindow": 3
}
```

配置说明：

| 配置项 | 含义 |
|---|---|
| `telegramToken` | BotFather Token；生产环境建议改用 Keychain/环境变量 |
| `ownerUserId` | 管理员 Telegram 数字 ID |
| `allowedChatId` | 允许控制的私聊或群聊 ID；省略时默认为管理员私聊 |
| `deviceMode` | `mock` 仅模拟，`ble` 连接真实设备 |
| `strengthLimit` | 项目强度上限，当前最多 133 |
| `sessionDurationSeconds` | 会话时长，默认 9999 秒 |
| `voteWindowSeconds` | 投票统计窗口，默认 5 秒 |
| `actionWindowMs` | 用户操作速率窗口，默认 1000 毫秒 |
| `actionsPerWindow` | 速率窗口内最多操作次数，默认 3 |

`config.json` 已被 `.gitignore` 排除，不能上传到公开仓库。环境变量会覆盖同名配置，支持 `TG_BOT_TOKEN`、`TG_OWNER_USER_ID`、`TG_ALLOWED_CHAT_ID`、`DG_DEVICE_MODE` 以及各项 `DG_*` 参数。

## 获取 Telegram 数字 ID

先确保 Bot 能接收消息，然后运行：

```bash
npm run telegram:ids
```

该命令只输出 `user_id`、`chat_id`、聊天类型和标题，不输出消息正文或 Token。多人投票时，把目标群的 `chat_id` 写入 `allowedChatId`；私信模式可以省略 `allowedChatId`。

## 首次 Mock 验证

先保持 `deviceMode` 为 `mock`：

```bash
npm run typecheck
npm test
npm run doctor
npm run demo
npm run dev
```

模拟模式不会扫描、连接或刺激蓝牙设备。Telegram 菜单会自动设置为中文，包括 `/start`、`/help`、`/join`、`/status`、`/connect`、`/newsession`、`/arm`、`/panel`、`/stop`、`/disarm` 和 `/disconnect`。

## macOS 蓝牙权限与真实设备

1. 打开「系统设置 → 隐私与安全性 → 蓝牙」；允许 Terminal、Node 或启动 Bot 的终端访问蓝牙。
2. 关闭手机 App 或其他程序对 DG-LAB 的连接。
3. 打开 DG-LAB 设备并靠近 Mac。
4. 运行只读扫描：

   ```bash
   npm run ble:scan
   ```

5. 扫描到 `D-LAB ESTIM01` 后运行安全探测：

   ```bash
   npm run ble:probe
   ```

   探测只连接、读取电量并归零，不播放波形。

6. 需要最低强度短测试时，必须显式执行：

   ```bash
   BLE_LOW_TEST=1 npm run ble:probe
   ```

确认硬件正常后，把 `deviceMode` 改为 `ble`，再启动 Bot。Bot 已经连接设备时，另一个进程可能扫描不到设备，这是正常的；应以 Bot 面板中的“设备：已连接”和电量为准。

## 启动 Bot

前台运行：

```bash
npm run dev
```

管理员操作顺序：

1. 点击「连接设备」或直接点击「授权并启动管理员会话」/「授权并启动投票会话」。
2. 设备连接成功后，A/B 会先归零并设为初始强度 1。
3. 管理员模式下，管理员按钮立即生效，其他成员只读。
4. 投票模式下，成员加入后投票；5 秒后按 A/B 强度和波形各自的最高票执行。
5. 管理员使用「撤销并归零」或「断开设备」结束会话。

## macOS LaunchAgent 常驻部署

### 1. 保存 Token 到 Keychain

```bash
security add-generic-password -a "$USER" -s dglab-telegram-bot -w
launchctl setenv TG_BOT_TOKEN "$(security find-generic-password -a "$USER" -s dglab-telegram-bot -w)"
```

### 2. 准备启动项

复制 `launchd/com.dglab.telegram-bot.plist.example` 到：

```text
~/Library/LaunchAgents/com.dglab.telegram-bot.plist
```

把模板中的路径、管理员 ID、允许聊天 ID 和 `DG_DEVICE_MODE` 改成自己的值。启动项不应写入 Token。

### 3. 加载、查看和停止

```bash
uid=$(id -u)
launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/com.dglab.telegram-bot.plist"
launchctl print "gui/$uid/com.dglab.telegram-bot"
launchctl kickstart -k "gui/$uid/com.dglab.telegram-bot"
launchctl bootout "gui/$uid/com.dglab.telegram-bot"
```

默认日志位置：`/tmp/dglab-telegram-bot.log` 和 `/tmp/dglab-telegram-bot.err.log`。

## 故障排查

### 提示“会话尚未启动”

重新发送 `/start` 获取最新菜单，使用“授权并启动管理员会话”或“授权并启动投票会话”。旧面板可能引用已结束的会话。

### Mac 显示蓝牙已开启但找不到设备

确认设备开机、未被手机 App 占用、Mac 已解锁并授予蓝牙权限。若 Bot 已经连接设备，独立扫描进程可能看不到它。

### 状态显示已连接但没有波形

投票模式需要等待完整 5 秒结算；管理员模式会立即生效。波形生效后会持续循环，直到切换或停止。检查强度是否大于 0，并确认实体设备处于可立即停止的位置。

### Bot 进程退出

```bash
npm run doctor
tail -f /tmp/dglab-telegram-bot.err.log
```

### 重新配置

停止 LaunchAgent，修改 `config.json` 或环境变量后，再执行 `launchctl kickstart -k`。不要把实际配置文件提交到 GitHub。

## 安全建议

- Token 只放在 Keychain、环境变量或未跟踪的 `config.json` 中。
- 公开仓库只包含 `config.example.json` 和占位符。
- 先用 `mock` 验证 Telegram 逻辑，再启用 BLE。
- 真实设备测试从强度 1 开始，并确保实体设备旁边有可立即停止的方式。
- 不要把 Bot 加入不受信任的群，也不要把管理员 ID 和聊天 ID 发布到截图中。

## 开源许可

本项目采用 MIT License，见 [LICENSE](LICENSE)。
