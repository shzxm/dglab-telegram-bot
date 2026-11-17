import SwiftUI
import AppKit

struct EnginePage: View {
    @EnvironmentObject private var model: ConsoleModel
    @State private var confirmRealEngine = false
    @State private var confirmStop = false

    var body: some View {
        Text("内置控制引擎").font(.largeTitle.bold())
        Text("Telegram Bot、蓝牙、OBS、音频辅助和本地 API 都包含在本 App 中。启动后由 App 管理同一个内部进程，不再依赖旧 LaunchAgent 或系统安装的 Node.js。")
            .foregroundStyle(.secondary)
        GroupBox("引擎运行状态") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: model.embeddedEngine.running ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(model.embeddedEngine.running ? .green : .secondary)
                    Text(model.serviceLabel).font(.headline)
                    Spacer()
                    Text("内置 Node.js 24").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    Button("启动 App 内置引擎") {
                        if model.selectedDeviceMode == "mock" { model.manageService("start") }
                        else { confirmRealEngine = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.embeddedEngine.running || model.isWorking)
                    Button("停止并断开所有控制") { confirmStop = true }
                        .disabled(!model.embeddedEngine.running || model.isWorking)
                    Button("安全 Mock 自检") { model.runSelfTest() }
                        .disabled(model.embeddedEngine.running || model.isWorking)
                    Button("刷新") { Task { await model.refresh(); await model.refreshServiceStatus() } }
                }
                Text("启动默认不会连接蓝牙或启动强度；真实设备连接和会话授权仍需要独立确认。只有确认零输出后才能停止引擎。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("设备与 Telegram 选项 · 仅影响下次启动") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("设备驱动", selection: $model.selectedDeviceMode) {
                    Text("模拟测试（默认）").tag("mock")
                    Text("Mac 直连蓝牙").tag("ble")
                    Text("iPhone 作为 BLE 主机").tag("ios")
                }.pickerStyle(.segmented).disabled(model.embeddedEngine.running)
                if model.selectedDeviceMode != "mock" {
                    Label("真实设备模式需要蓝牙授权、实体急停措施和现场验证，软件数值上限不代表人体安全强度。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("启用 Telegram Bot 与聊天控制（关闭时本地全部页面仍可使用）", isOn: $model.telegramEnabled)
                    .disabled(model.embeddedEngine.running)
                HStack(spacing: 12) {
                    TextField("Telegram 管理员数字 ID", text: $model.ownerUserID)
                        .textFieldStyle(.roundedBorder)
                    TextField("允许的群或聊天 ID（可留空）", text: $model.allowedChatID)
                        .textFieldStyle(.roundedBorder)
                }.disabled(model.embeddedEngine.running)
                HStack {
                    Button("读取旧版非敏感设置与凭证") { model.importLegacyConfiguration() }
                    Text(model.botTokenPresent ? "Telegram 凭证可用（不显示）" : "Telegram Token 尚未配置")
                        .font(.caption).foregroundStyle(model.botTokenPresent ? .green : .secondary)
                    Spacer()
                }
                HStack {
                    SecureField("粘贴自己的 BotFather Token", text: $model.enteredBotToken)
                    Button("安全保存到钥匙串") { model.saveBotToken() }
                }
                Text("Bot Token 不会写入安装包、日志、仓库或配置 JSON。首次启用 Telegram 前，请确认账号和管理员 ID。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("iOS App 互动与 API") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("iPhone 桥接监听")
                    TextField("127.0.0.1（仅本机）或可信 LAN IP", text: $model.bridgeHost)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.embeddedEngine.running)
                }
                Text("本机 REST API：127.0.0.1:\(model.apiPort)。iPhone WebSocket：\(model.bridgeHost):8788。仅在可信局域网可把桥接地址改为 Mac 的内网 IP，不得直接向公网暴露。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("桥接密钥在 App 钥匙串保存，iOS 客户端输入同一密钥。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .confirmationDialog("启动真实设备模式的完整控制引擎？", isPresented: $confirmRealEngine) {
            Button("确认启动（不会自动连接或授权输出）") { model.manageService("start") }
        } message: { Text("启动后 Telegram Bot 可连接网络；真正发出设备指令前仍需现场确认。") }
        .confirmationDialog("停止整个 App 内置控制引擎？", isPresented: $confirmStop) {
            Button("确定停止") { model.manageService("stop") }
        } message: { Text("将依次停止声音响应和自动提升、归零会话、断开蓝牙、停止 API/Telegram 并等待内置进程结束。若无法确认安全关闭，会保留引擎并显示错误。") }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let status: String
    let actionLabel: String
    let action: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).frame(width: 27)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Text(status).font(.caption.monospacedDigit())
                    .foregroundStyle(status.contains("已授权") || status.contains("测试通过") ? .green : .orange)
            }
            Spacer(minLength: 8)
            Button(actionLabel, action: action)
            Button("系统设置", action: settings)
        }
        .padding(.vertical, 8)
    }
}

struct PermissionsPage: View {
    @ObservedObject private var permissions = PermissionCenter.shared

    var body: some View {
        Text("系统权限中心").font(.largeTitle.bold())
        Text("每个权限独立申请；只有点击按钮时才会触发相应系统提示。macOS 已拒绝的权限通常不能重复弹窗，只能通过系统设置修改。")
            .font(.subheadline).foregroundStyle(.secondary)
        HStack {
            Button("刷新全部权限状态") { permissions.refresh() }
            Spacer()
            Text("不修改系统 TCC 数据库，不强制绕过用户选择")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !permissions.message.isEmpty {
            Label(permissions.message, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        GroupBox("设备及声音输入") {
            VStack(alignment: .leading, spacing: 0) {
                PermissionRow(icon: "bolt.horizontal.circle", title: "蓝牙", subtitle: "扫描、连接 DG-LAB V2 所需；请求由本 App 发起，不自动连接设备。",
                    status: permissions.bluetooth, actionLabel: "申请蓝牙", action: permissions.requestBluetooth,
                    settings: { permissions.openSettings("Privacy_Bluetooth") })
                Divider()
                PermissionRow(icon: "mic", title: "麦克风（可选）", subtitle: "仅麦克风功能需要，Mac 系统声音分析不依赖麦克风。",
                    status: permissions.microphone, actionLabel: "申请麦克风", action: permissions.requestMicrophone,
                    settings: { permissions.openSettings("Privacy_Microphone") })
                Divider()
                PermissionRow(icon: "rectangle.dashed.badge.record", title: "屏幕与系统音频录制", subtitle: "打开系统设置的权限页，同时触发 ScreenCaptureKit 申请；授权后可能需要重新启动 App。",
                    status: permissions.screen, actionLabel: "申请录屏", action: permissions.requestScreen,
                    settings: { permissions.openSettings("Privacy_ScreenCapture") })
                Divider()
                PermissionRow(icon: "waveform", title: "系统音频录制", subtitle: "独立测试 ScreenCaptureKit 音频抓取：只读取不到 1 秒的音频指标，不保存内容。",
                    status: permissions.systemAudio, actionLabel: permissions.audioTesting ? "测试中" : "申请并测试", action: permissions.testSystemAudio,
                    settings: { permissions.openSettings("Privacy_ScreenCapture") })
            }.padding(.horizontal, 10)
        }
        GroupBox("局域网与通知") {
            VStack(alignment: .leading, spacing: 0) {
                PermissionRow(icon: "network", title: "局域网", subtitle: "仅当 iPhone 从局域网访问 Mac 的桥接服务时需要，不会影响本机蓝牙。",
                    status: "无统一状态读取接口；按使用场景申请", actionLabel: "查看说明", action: {
                        let alert = NSAlert()
                        alert.messageText = "DG-LAB 局域网权限说明"
                        alert.informativeText = "局域网权限用于让 iPhone 访问 Mac 的 WebSocket 桥接（8788）。在内置引擎页面把桥接监听改为可信的 Mac 内网 IP，并由手机尝试连接时，系统可能提示授权。本机独立控制不需要此权限，请勿向公网开放 8788。"
                        alert.addButton(withTitle: "明白")
                        alert.runModal()
                    }, settings: { permissions.openSettings("Privacy_LocalNetwork") })
                Divider()
                PermissionRow(icon: "bell", title: "通知（可选）", subtitle: "未来的断线或异常告警可使用系统通知，不是蓝牙输出的必要权限。",
                    status: permissions.notifications, actionLabel: "申请通知", action: permissions.requestNotifications,
                    settings: { permissions.openSettings("Notifications") })
                Divider()
                PermissionRow(icon: "hand.point.up.left", title: "辅助功能（可选）", subtitle: "普通 DG-LAB 控制不需要，仅用于未来的 GUI 自动化场景。",
                    status: permissions.accessibility, actionLabel: "申请辅助功能", action: permissions.requestAccessibility,
                    settings: { permissions.openSettings("Privacy_Accessibility") })
            }.padding(.horizontal, 10)
        }
        Text("说明：权限状态仅对应 macOS 的授权记录，不保证随 App 启动的音频助手或蓝牙驱动已经成功捕获/连接。最终仍要以实际功能诊断为准。")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 5)
        .onAppear { permissions.refresh() }
    }
}
