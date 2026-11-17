# DG-Lab Control iOS（非官方、实验性）

本目录是使用 SwiftUI、CoreBluetooth 和原生安全状态机编写的 iOS App，与本仓库的 Node.js Telegram Bot 协同。它不包含 Telegram Bot Token 或用户聊天记录。

## 能力

- 通过 CoreBluetooth 连接 DG-Lab V2，读取电量，连接/断开时尝试归零。
- A/B 两通道强度、波形、独立上限及紧急停止；软件上限不是安全阈值。
- 手动设置自动提升间隔 1–60 秒、每次累计最多 +33 级的上限；达到上限或到期即停止。
- 固定及双手柄 1–100 Hz 范围、麦克风/应用内声音响应、无音频内容上传。
- 通过独立 WebSocket 密钥连接 Mac Bot，复用 Telegram 会话、投票、活动模式和群组状态；可切换手机 BLE 主机角色。
- App → 药时的显式深度链接，见 [互通协议](../docs/PK_ATLAS_INTEROPERABILITY.md)。

## 编译

需要 Xcode 27.2 / iOS SDK 27.2、XcodeGen 2.46+：

~~~bash
cd ios
xcodegen generate --spec project.yml
swift test
xcodebuild -project DGLabControl.xcodeproj -scheme DGLabControl \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
~~~

签名安装需要自己的 Apple Developer Team / Bundle ID 和相应描述文件。本仓库**不提供签名 IPA 或作者证书**。

## 与 macOS Bot 桥接

在 Mac Bot 的配置中设置单独生成的、至少 32 字符的 IOS_BRIDGE_TOKEN；默认 IOS_BRIDGE_HOST=127.0.0.1、IOS_BRIDGE_PORT=8788。为了从 iPhone 连接，改为可信局域网主机地址，并限制防火墙访问；跨网必须通过经身份验证的 WSS 服务。

首次在 iOS App 内填写对应的 ws://<Mac-LAN-IP>:8788 地址和独立桥接密钥，凭据存入 iOS Keychain。iOS 端默认不填写私人地址，不会自动连接陌生设备；若切换到 ios 模式，先停止活动会话、解除 MBP 蓝牙占用，再于 iPhone 本地显式授权。

## 重要安全限制

- 未进行真实人体刺激场景的安全认证；模拟器构建成功不能替代真实硬件/真机验收。
- iOS 切后台或应用被强制退出，不能保证 100ms 的 BLE 波形写入及时完成。不要作为医疗或生命安全控制器使用。
- 新设备必须有独立物理紧急停止手段；即使软件报告“已停止”，仍需观察实体输出。
- 任何来自其他 App 的 dglabcontrol://open 链接只打开本应用，不授权、不自动发出蓝牙指令。
