# DG-LAB Console for macOS (独立版)

基于原生 SwiftUI 的 DG-LAB V2 控制端。**本版把完整 Node.js 运行时、Telegraf Telegram Bot、BLE 控制、波形、双通道自动提升、ScreenCaptureKit 系统声音分析、OBS、本地 HTTP API 和 iOS WebSocket 桥接一并封装到 `.app` 内**。

App **不依赖** Homebrew Node.js、单独的 `com.dglab.telegram-bot` LaunchAgent 或外部已运行的 Bot 服务。实现方式是 SwiftUI 主进程 + App 内的 Node.js 子进程，它们同属一个应用安装包；**不是全 Swift 重写**。

## 首次操作

1. 打开 `DG-LAB Console.app`，进入「**权限中心**」。根据需要逐项点击蓝牙、屏幕录制、系统音频测试、麦克风和通知权限；已拒绝的权限需前往系统设置修改。系统音频测试仅短时捕获，不保存音频或屏幕。
2. 进入「**内置引擎**」。设备默认 `mock`（不接触硬件）；可选择 `ble`（Mac 蓝牙）或 `ios`（iPhone 蓝牙主机），但必须在现场确认设备和硬件急停方式后切换。
3. 若需要 Telegram，开启 Telegram 选项，填写 BotFather Token、管理员数字 ID 或点击「仅导入旧版非敏感设置」。Token 手动保存到 App 私有目录，不访问 macOS Keychain，也不进入安装包。
4. 点击 **启动 App 内置引擎**，待页面显示 API 已连接；然后在总览、A/B 通道、声控、Telegram 和 API 页面使用功能。关闭 GUI 窗口不会启动额外 Bot，退出 App 前必须先停止活动输出。

## 功能

- **设备与会话**：Mock/真实 macOS BLE/iPhone BLE 主机模式，连接/断开、A/B 强度、9 种波形、独立会话上限、停止/归零。
- **双通道自动提升**：间隔 1–60 秒、本轮累计提升 +1 至 +33 级后停止，A/B 分别设置、倒数和进度。
- **声音响应**：系统音频音量和节拍模式可单独或同时启用；固定频率、常见区间及自定义 1–100 Hz。
- **Telegram 多人协作**：邀请码、群绑定、投票、活动队列、抽选与动作池。Telegram 选项关闭后，**本地 Mock/控制面板仍可以工作**，无需 Bot Token。
- **系统权限中心**：蓝牙、屏幕录制、系统音频捕获测试、麦克风、局域网设置、通知及可选辅助功能。明确提示授权状态，不绕过 macOS TCC。
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
open "$HOME/Library/Caches/DGLabConsole/Release/DG-LAB Console.app"
```

`prepare-runtime.sh` 使用**固定 SHA-256 验证** Node.js 24.13.0 官方 ARM64 二进制，安装生产依赖、编译原本 TypeScript 与系统音频助手。运行时编译缓存默认位于 `~/Library/Caches/DGLabConsole/Runtime/`（不在文件同步目录内），不会提交到仓库。完整 `.app` 包括 `Contents/MacOS/DGLabConsole`、`Contents/Helpers/node`、`Contents/Helpers/dglab-system-audio-meter`、`Contents/Resources/Engine`。

MBP 如果只有 Command Line Tools 而没有完整 Xcode，可以在另一台有完整 Xcode 的 Mac 编译图形可执行程序，然后在 MBP 用 `DG_GUI_BINARY=/path/to/DGLabConsole ./Scripts/build-app.sh` 把自己的内置运行时一起打包。

## 与 iOS App 的关系

iOS App [dglab-ios](https://github.com/shzxm/dglab-ios) 可选择完全独立蓝牙控制，也可通过 WebSocket 桥接与 macOS App 内的引擎共享 Telegram 会话。Mac BLE / iPhone BLE 两种主机模式不能同时连接同一设备。iOS 桥接通过独立高熵密钥授权，**不复制 Telegram Bot Token 到手机**。

详见 [本地 API](../../docs/LOCAL_CONTROL_API.md)、[桥接协议](../../docs/IOS_BRIDGE.md) 与 [架构](../../docs/ARCHITECTURE.md)。

## 依赖许可证

本 App 的源代码采用仓库的 MIT License。完整安装包还包含 Node.js 24 官方运行时（含第三方组件许可通知）及若干生产版 npm 包。`prepare-runtime.sh` 会将官方 Node.js 的许可证提取到 App 的 `Contents/Resources/Engine/NODEJS_LICENSE.txt`，npm 依赖各自的许可证文件保留在相应 `node_modules` 内。发布或二次分发必须保留这些文件。

为防止 iCloud/文件提供程序自动给源码目录中的 `.app` 添加 FinderInfo 扩展属性而破坏签名，`build-app.sh` 默认将可验证的输出放在 `~/Library/Caches/DGLabConsole/Release/DG-LAB Console.app`。也可通过 `DG_APP_OUTPUT_DIR` 指定非同步磁盘目录。发布前请先用 `codesign --verify --deep --strict` 检查完整包。

## v1.1.1 状态、权限与退出修正（2026-11-17）

- **设备连接**：连接请求等待时间长于 15 秒蓝牙扫描窗口，避免把正常搜索误报为 App 的 7 秒请求超时。连接失败在主界面显示「设备未连接」，详细原因保留在最近操作日志；未完成扫描时禁止重复连接。
- **设备刷新**：状态每 **1 秒**重新查询一次（GET 超时 2.5 秒），前一次请求尚未结束则不重叠；未接通的真实设备和 API 断线分别显示。
- **A/B 投票**：界面是 A/B 两套独立投票卡片，每套都有独立强度 ±1/±3/±5、波形选择、实时票数。
- **权限**：「申请录屏」会打开系统设置中的录屏授权页面并发起操作系统的申请；「局域网 → 查看说明」立即弹出独立说明窗。原「文件选择」仅为演示，并非 DG-LAB 功能，因此已经从权限页移除。
- **内置引擎停止/退出**：点击停止或正常退出 App（含最后窗口关闭）会**先发送 `session.disconnect` 并等待确认**：停止声控与自动提升、结束当前会话、归零及断开设备；随后回读会话与设备状态，确认 A/B 均为零且设备已断开，才通知内置 Node 退出并等待进程结束。如果设备失联、API 不回应或结果不确定，App 会取消本次退出并保留控制界面给用户处理，不能用一条本地“退出成功”消息替代硬件安全证明。

**注意**：应用内的数值归零不等于在网络/蓝牙失联后实体设备一定执行了归零，仍必须准备独立硬件停止方式。

- 系统音频权限测试助手现在归 App 生命周期管理，正常退出时会主动终止此独立测试进程。授权界面由 macOS TCC 决定，应用不能代替用户点击批准。

## v1.2.0：App 私有密钥和日志导出

- **不再调用 macOS 钥匙串**。API / iOS 桥接密钥与 Telegram Bot Token 持久化于 `~/Library/Application Support/DG-LAB Console/credentials.json`；目录 `0700`，文件 `0600`，用临时文件和原子替换写入。
- 这个存储位置**不是 `.app` 安装包**，替换或升级应用不会擦除已有密钥，也不会将用户密钥发布到 GitHub。不同于 Keychain，文件使用权限隔离而不是钥匙串加密，同一账户下有文件权限的程序可以读取，请自行保护本机账户。
- **首次迁移**：为避免钥匙串弹窗，不自动读取此前的 Keychain 项目。第一次打开新版会生成新的独立桥接密钥；需要继续连接已配置旧密钥的 iOS App 时，应手动同步新密钥，或在新版「本地 API」页面手动填入与 iOS 相同的原密钥。Telegram Bot Token 同样需手动重新填入一次。修改密钥后应重启已启动的内置引擎，使双方使用相同配置。
- **日志**：App 交互记录、内置 Node stdout/stderr 及错误信息脱敏保存在 `~/Library/Application Support/DG-LAB Console/Logs/`。轮转保留 `dg-lab.log` 与最多 3 份历史文件，每份约 2MB；文件权限 `0600`，目录 `0700`。
- **导出**：在「本地 API → 诊断日志与导出」点击「导出诊断日志…」，使用系统保存对话框选择文件。导出带 ISO8601 时间戳、日志来源、App/macOS 版本信息，自动遮盖 `Bearer`、Telegram Token、当前已知密钥等；**导出是可共享的普通文本文件，不会加密**，分享前请人工检查。
- 不再依赖用户手动复制控制台最近 10 行；导出包含持续日志和轮转记录。为避免巨量磁盘占用，只保留有界历史。
- 可在安装完整 Xcode 的 Mac 上运行 `./macos/DGLabConsole/Scripts/test-private-storage.sh` 验证持久化、`0700/0600` 权限和日志脱敏。测试使用隔离的 `/tmp` 目录，不触碰真实配置。

- **安全限制**：内置 Node 引擎运行时禁止直接修改 API 密钥，因为新旧 Bearer 不一致会导致 App 无法向旧引擎发送安全停止命令。请先安全停止内置引擎，再修改并重新启动。
