# DG-LAB Console for macOS (独立版)

基于原生 SwiftUI 的 DG-LAB V2 控制端。**本版把完整 Node.js 运行时、Telegraf Telegram Bot、BLE 控制、波形、双通道自动提升、ScreenCaptureKit 系统声音分析、OBS、本地 HTTP API 和 iOS WebSocket 桥接一并封装到 `.app` 内**。

App **不依赖** Homebrew Node.js、单独的 `com.dglab.telegram-bot` LaunchAgent 或外部已运行的 Bot 服务。实现方式是 SwiftUI 主进程 + App 内的 Node.js 子进程，它们同属一个应用安装包；**不是全 Swift 重写**。

## 首次操作

1. 打开 `DG-LAB Console.app`，进入「**权限中心**」。根据需要逐项点击蓝牙、屏幕录制、系统音频测试、麦克风和通知权限；已拒绝的权限需前往系统设置修改。系统音频测试仅短时捕获，不保存音频或屏幕。
2. 进入「**内置引擎**」。设备默认 `mock`（不接触硬件）；可选择 `ble`（Mac 蓝牙）或 `ios`（iPhone 蓝牙主机），但必须在现场确认设备和硬件急停方式后切换。
3. 若需要 Telegram，开启 Telegram 选项，填写 BotFather Token、管理员数字 ID 或点击「读取旧版非敏感设置与凭证」。Token 单独保存在 Keychain 中，不进入安装包。
4. 点击 **启动 App 内置引擎**，待页面显示 API 已连接；然后在总览、A/B 通道、声控、Telegram 和 API 页面使用功能。关闭 GUI 窗口不会启动额外 Bot，退出 App 前必须先停止活动输出。

## 功能

- **设备与会话**：Mock/真实 macOS BLE/iPhone BLE 主机模式，连接/断开、A/B 强度、9 种波形、独立会话上限、停止/归零。
- **双通道自动提升**：间隔 1–60 秒、本轮累计提升 +1 至 +33 级后停止，A/B 分别设置、倒数和进度。
- **声音响应**：系统音频音量和节拍模式可单独或同时启用；固定频率、常见区间及自定义 1–100 Hz。
- **Telegram 多人协作**：邀请码、群绑定、投票、活动队列、抽选与动作池。Telegram 选项关闭后，**本地 Mock/控制面板仍可以工作**，无需 Bot Token。
- **系统权限中心**：蓝牙、屏幕录制、系统音频捕获测试、麦克风、局域网设置、通知、文件选择及可选辅助功能。明确提示授权状态，不绕过 macOS TCC。
- **OBS 与 API**：`127.0.0.1:8787/obs`、`127.0.0.1:8789/v1/status|capabilities|command`；手机 WebSocket 端口默认 8788。Bearer 鉴权，连接设备/启动输出需要二次确认。

## 安全边界

- 初始设备模式 `mock`；启动内置引擎**不自动连接蓝牙**或开始输出。
- 同时只能有**一个控制引擎**：App 检查本地端口，若旧 Node/LaunchAgent 已运行则拒绝重复启动。建议让旧 `com.dglab.telegram-bot` 保持关闭。
- 退出 App 前检查 A/B 会话与设备输出，非零或状态不确定时拒绝关闭；用户先按紧急停止再退出。内置引擎定时检查父进程是否仍存活，异常退出时尝试安全停机。
- 软件停止/归零**不能保证失联设备一定收到指令**。任何实际使用必须有单独、立即可用的物理停止或断开手段。`133` 为软件档位范围，**不是人体安全阈值**。
- 当前为临时 ad-hoc 签名版，非 Apple Developer ID 签名或公证；蓝牙、ScreenCaptureKit 权限归属可能与独立音频助手有关，必须在 MBP 上点按钮实际授权并检查。

## 开发与打包

运行需 macOS 14+、Apple Silicon。**运行不需要外部 Node、Homebrew 或完整 Xcode**。构建需完整 Xcode（macOS SwiftUI 编译），以及准备运行时的 Node/npm 和网络：

```bash
cd dglab-telegram-bot
./macos/DGLabConsole/Scripts/prepare-runtime.sh
cd macos/DGLabConsole
./Scripts/build-app.sh
open 'build/DG-LAB Console.app'
```

`prepare-runtime.sh` 使用**固定 SHA-256 验证** Node.js 24.13.0 官方 ARM64 二进制，安装生产依赖、编译原本 TypeScript 与系统音频助手。编译产物在 `.runtime-cache/`，不会提交到仓库。完整 `.app` 包括 `Contents/MacOS/DGLabConsole`、`Contents/Helpers/node`、`Contents/Helpers/dglab-system-audio-meter`、`Contents/Resources/Engine`。

MBP 如果只有 Command Line Tools 而没有完整 Xcode，可以在另一台有完整 Xcode 的 Mac 编译图形可执行程序，然后在 MBP 用 `DG_GUI_BINARY=/path/to/DGLabConsole ./Scripts/build-app.sh` 把自己的内置运行时一起打包。

## 与 iOS App 的关系

iOS App [dglab-ios](https://github.com/shzxm/dglab-ios) 可选择完全独立蓝牙控制，也可通过 WebSocket 桥接与 macOS App 内的引擎共享 Telegram 会话。Mac BLE / iPhone BLE 两种主机模式不能同时连接同一设备。iOS 桥接通过独立高熵密钥授权，**不复制 Telegram Bot Token 到手机**。

详见 [本地 API](../../docs/LOCAL_CONTROL_API.md)、[桥接协议](../../docs/IOS_BRIDGE.md) 与 [架构](../../docs/ARCHITECTURE.md)。
