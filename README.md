# DG-LAB Telegram Bot

当前版本是安全的开发版：默认使用 `MockDevice`，不会连接蓝牙。只有设置 `DG_DEVICE_MODE=ble` 才会启用 Mac 上的 DG-LAB 2.0 BLE 适配器。

## 配置与本地启动

```bash
npm install
cp config.example.json config.json
# 编辑 config.json，填写自己的 Telegram 配置；不要提交 config.json
npm run typecheck
npm test
npm run dev
```

也可以使用环境变量覆盖配置文件。令牌建议放在 macOS Keychain，而不是配置文件中。

默认安全参数：强度上限 `133`、会话时长 `9999` 秒、投票窗口 `5` 秒、每位用户每秒最多 `3` 次操作。

开发阶段建议保持 `DG_DEVICE_MODE=mock`。Bot 命令流程：

1. `/newsession` 创建协作会话；发送 `/newsession voting` 创建投票会话。
2. `/arm` 仅所有者可以授权开始。
3. 群成员 `/join` 后使用控制面板。
4. 管理员模式由管理员直接操作；其他成员只读查看面板。
5. 投票模式按 5 秒窗口统计票数后执行最高票动作。
6. `/stop` 可立即停止，`/disarm` 由所有者撤销授权，`/disconnect` 停止并断开设备。

完全离线演示两种模式（不会连接 Telegram 或蓝牙）：

```bash
npm run demo
```

检查运行环境（不会连接 Telegram 或设备，也不会打印 Token）：

```bash
npm run doctor
```

只检查 Mac 是否能发现二代设备（不连接、不写入、不输出）：

```bash
npm run ble:scan
```

扫描成功后，可执行一次安全硬件探测（只连接、读取电量并归零，不播放波形）：

```bash
npm run ble:probe
```

确认设备连接正常后，才可显式执行一次最低级别短波形测试（A=1，约0.5秒）：

```bash
BLE_LOW_TEST=1 npm run ble:probe
```

## BLE 模式注意事项

首次必须在 macOS 已登录桌面中运行并授予终端/Node 蓝牙权限。程序连接成功后会先写入 A/B 零值。真实设备测试前应使用很低的会话上限，并确保实体设备在可立即停止的位置。

Bot Token 只能通过环境变量或 macOS Keychain 注入，不要写入源代码、`.env`、日志或 Git。之前公开过的 Token 必须先在 BotFather 撤销。

启动时会校验 Token 格式、所有者 ID、群 ID 和设备模式；模板占位符不会被接受。省略 `TG_ALLOWED_CHAT_ID` 时，默认只允许管理员自己的私聊。

如果不知道数字 ID，可先私聊机器人发送 `/start`，并在目标群发送一条普通消息，再运行 `npm run telegram:ids`。该命令只输出 `user_id/chat_id`，不输出消息内容。

## macOS 常驻运行

先把新 Token 保存到当前用户 Keychain（以下命令会要求你手动输入 Token，不要把 Token 写入文件）：

```bash
security add-generic-password -a "$USER" -s dglab-telegram-bot -w
launchctl setenv TG_BOT_TOKEN "$(security find-generic-password -a "$USER" -s dglab-telegram-bot -w)"
```

然后将 `launchd/com.dglab.telegram-bot.plist.example` 复制到 `~/Library/LaunchAgents/`，替换其中的路径和占位符，并设置 `DG_DEVICE_MODE=mock` 完成首次 Bot 逻辑验证。真实 BLE 验证通过后再改为 `ble`。
