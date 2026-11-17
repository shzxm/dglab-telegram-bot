# DG-LAB 控制台 for macOS

[DG-LAB Telegram Bot 主仓库](https://github.com/shzxm/dglab-telegram-bot) · [iOS 客户端](https://github.com/shzxm/dglab-ios) · MIT

本项目是 DG-LAB V2 Telegram Bot 的 **原生 SwiftUI macOS 图形控制台**，不是第二个 Telegram Bot。所有真实蓝牙、波形和会话仍由同一个已部署的 Node.js 服务负责，App 提供一站式操作面板，避免从聊天菜单和命令行中反复切换。

## 控制功能

- **总览**：API / 蓝牙设备状态、电量、A/B 当前强度、参与人数；创建管理员/投票/活动会话、明确确认后授权启动；设备连接/断开、紧急停止。
- **A/B 双通道**：独立 ±1/±3/±5 调整；9 组波形；1–60 秒自动提升间隔和本轮自动增加 1–33 级上限；各自启停与进度。
- **声音响应**：macOS 系统音量与节拍响应，双模式可分别启停；A/B/双通道目标；固定 1/20/50/100 Hz、4 组常用范围和自定义 1–100 Hz 端点。
- **Telegram/直播**：邀请码、管理员加入、队列、随机操作员、动作池、群绑定及强度/波形投票。
- **API / 服务**：Keychain 凭证、HTTP 状态/命令、可编辑 JSON 请求、访问代码示例；查看现有 LaunchAgent、启动、安全重启或停止后台。
- **OBS**：打开由现有 Bot 托管的 `/obs` 页面。

## 安装

已部署 Bot 的 Mac：

```bash
cd dglab-telegram-bot/macos/DGLabConsole
./Scripts/build-app.sh
mkdir -p "$HOME/Applications"
cp -R 'build/DG-LAB Console.app' "$HOME/Applications/"
open "$HOME/Applications/DG-LAB Console.app"
```

运行需要 macOS 14+。**构建需要完整 Xcode 27.2（或具备 SwiftUI 宏插件的兼容版本）**：MBP 的单独 Command Line Tools 可以解析普通 SwiftUI 类型，但缺少 SwiftUIMacros 编译插件，无法独立构建此图形界面。可在 Mac mini 等装有完整 Xcode 的机器构建 `.app` 后直接安装到 MBP，运行应用不需要安装 Xcode。生成的 `.app` 使用**临时 ad-hoc 签名**，不属于公证发行包。

首次打开时 App 会尝试从当前用户钥匙串读取服务名 `dglab-ios-bridge` 的独立桥接密钥。若需要批准读取，请在 macOS 授权；也可在「API 与服务」页面填写该密钥并保存到 App 专属 Keychain。**不要输入 BotFather Token。**

运行时依赖现有 Node.js 后台服务及其 LaunchAgent。UI 默认访问 `http://127.0.0.1:8789`，不启动第二个 Bot，也不复制当前用户配置。

## 启用本地 API

macOS Bot 需要 `IOS_BRIDGE_TOKEN`（至少 32 字符）；和 iOS WebSocket 桥接共用这份**独立于 Telegram Token 的管理员密钥**，默认自动启用：

- `GET http://127.0.0.1:8789/health`：本机健康，不返回设备秘密。
- `GET http://127.0.0.1:8789/v1/status`：需 Bearer，返回会话、设备、电量、音频、自动提升和 OBS 位置。
- `GET http://127.0.0.1:8789/v1/capabilities`：需 Bearer，返回可用命令、波形、范围。
- `POST http://127.0.0.1:8789/v1/command`：需 Bearer，命令和参数走白名单与原会话权限校验。

`DG_LOCAL_API_PORT=8789` 可改端口，但 API **始终只监听 127.0.0.1**，不可开放到公网。详细请求示例见 [../../docs/LOCAL_CONTROL_API.md](../../docs/LOCAL_CONTROL_API.md)。

**需要二次确认的命令**：`session.arm` 必须设置 `X-DGLab-Confirm: arm`，`device.connect` 必须设置 `X-DGLab-Confirm: connect`。App 按钮会先弹出确认窗口。其他命令遵守服务端现有强度上限和速率限制。

## 重要设计选择

1. **一个 Bot 进程**：macOS GUI / iOS App / Telegram 群共享同一份 ControlSession。App 退出不结束 Bot，会话仍由原来的后台服务管理。
2. **API 最小暴露**：仅监听回环、本机密钥认证、命令白名单、命令速率限制，浏览器跨源请求被拒绝；不会提供 shell exec API。
3. **服务管理防护**：只有当 API 新鲜读取确认 `active=false` 且会话与设备 A/B 都为 0，才允许 App 停止或重启 LaunchAgent。若无法判断，拒绝操作。
4. **设备安全**：软件在会话停止、BLE 错误时尝试归零，但断连情况下无法保证控制包抵达。实体设备必须有独立、立即可用的停止/断开方式。`133` 为软件数值上限，不代表人体安全值。
5. **设备模式**：`DG_DEVICE_MODE=ble` 由 Mac 控制 DG-LAB，`ios` 模式把设备输出托管给 iPhone，`mock` 模式仅测试。App 不会自动切换现有部署的设备模式。

## 界面与接口测试

```bash
swift build --jobs 2
./Scripts/build-app.sh
cd ../..
npm run typecheck
npm test
npm run build
```

命令行/模拟 Mock 通过不能替代 DG-LAB 实体蓝牙验收。导出时不要将 `.env`、`config.json`、Keychain 密钥或签名文件放入 `.app` 与仓库。
