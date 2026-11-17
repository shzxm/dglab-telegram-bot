import AppKit
import SwiftUI

private enum Page: String, CaseIterable, Identifiable {
    case overview = "总览"
    case channels = "A/B 通道"
    case audio = "声音响应"
    case telegram = "Telegram / 活动"
    case api = "API 与服务"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .channels: return "slider.horizontal.3"
        case .audio: return "waveform"
        case .telegram: return "person.2.bubble"
        case .api: return "terminal"
        }
    }
}

private let waveforms: [(id: String, name: String)] = [
    ("imported_0", "波浪"), ("imported_1", "持续跳跃"), ("imported_2", "渐强持续"),
    ("imported_3", "最爱"), ("imported_4", "按揉"), ("imported_5", "跳强"),
    ("soft", "柔和基础"), ("rhythm", "节奏基础"), ("rise", "上升基础")
]

struct ConsoleWindow: View {
    @EnvironmentObject private var model: ConsoleModel
    @State private var selection: Page? = .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationTitle("DG-LAB")
            .navigationSplitViewColumnWidth(min: 175, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: model.connected ? "checkmark.circle.fill" : "wifi.slash")
                        .foregroundStyle(model.connected ? .green : .orange)
                    Text(model.connected ? "本地 API 已连接" : "本地 API 未连接")
                        .font(.subheadline.weight(.medium))
                    Text(model.snapshot?.deviceMode?.uppercased() ?? "未知模式")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let state = model.snapshot {
                        Text("A \(state.strengthA ?? 0)  /  B \(state.strengthB ?? 0)")
                            .font(.subheadline.monospacedDigit())
                    }
                    Button("刷新") { Task { await model.refresh() } }
                    Button(role: .destructive) { model.emergencyStop() } label: {
                        Label("立即停止并尝试归零", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!model.connected)
                }
                .padding(14)
                .background(.quaternary.opacity(0.30))

                if !model.errorMessage.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(model.errorMessage).font(.caption)
                        Spacer()
                        Button { model.errorMessage = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                    .padding(10).background(.orange.opacity(0.07))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        switch selection ?? .overview {
                        case .overview: OverviewPage()
                        case .channels: ChannelsPage()
                        case .audio: AudioPage()
                        case .telegram: TelegramPage()
                        case .api: APIPage()
                        }
                        if !model.lastMessage.isEmpty {
                            Text(model.lastMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(selection?.rawValue ?? "控制台")
        }
    }
}

private struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OverviewPage: View {
    @EnvironmentObject private var model: ConsoleModel
    @State private var sessionMode = "collaboration"
    @State private var confirmArm = false
    @State private var confirmConnect = false
    @State private var confirmDisconnect = false

    var body: some View {
        Text("概览").font(.largeTitle.bold())
        let state = model.snapshot
        HStack(spacing: 10) {
            Metric(label: "会话", value: state?.sessionState == "active" ? "进行中" : state?.sessionState == "draft" ? "待授权" : "未启动")
            Metric(label: "设备", value: state?.device?.connected == true ? "已连接" : "未连接")
            Metric(label: "设备电量", value: state?.device?.connected == true ? "\(state?.device?.battery ?? 0)%" : "--")
            Metric(label: "参与人数", value: "\(state?.participants ?? 0)")
        }
        GroupBox("会话与设备") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("会话模式")
                    Picker("", selection: $sessionMode) {
                        Text("管理员").tag("collaboration")
                        Text("投票").tag("voting")
                        Text("活动/直播").tag("event")
                    }.labelsHidden().frame(width: 185)
                    Button("创建未授权会话") {
                        model.command("session.create", payload: ["mode": sessionMode])
                    }.disabled(state?.isActive == true || !model.connected)
                    Button("授权并开始") { confirmArm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(state?.sessionState != "draft")
                }
                Divider()
                HStack {
                    Button("连接设备并归零") { confirmConnect = true }
                        .disabled(!model.connected || state?.isActive == true)
                    Button("停止并断开设备") { confirmDisconnect = true }
                        .disabled(!model.connected)
                    Spacer()
                    if let url = model.obsURL {
                        Link("打开 OBS 叠加层", destination: url)
                    }
                }
                Text("启动会话可能设置默认强度 1。必须确认真实设备、线路和独立停止方式就绪。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        GroupBox("当前状态") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("连接方式", value: state?.deviceMode ?? "未知")
                LabeledContent("控制模式", value: state?.mode ?? "--")
                LabeledContent("A / B 强度", value: "\(state?.strengthA ?? 0) / \(state?.strengthB ?? 0)")
                LabeledContent("会话限制", value: "\(state?.strengthLimit ?? 0)（软件值，非安全阈值）")
                LabeledContent("声控", value: "音量 \(state?.audioVolume == true ? "开" : "关") · 节拍 \(state?.audioBeat == true ? "开" : "关")")
                LabeledContent("A / B 自动提升", value: "\(state?.rampA == true ? "开" : "关") / \(state?.rampB == true ? "开" : "关")")
            }
            .padding(10)
        }
        .confirmationDialog("授权并启动设备会话？", isPresented: $confirmArm) {
            Button("我确认设备已准备，开始会话") { model.command("session.arm", confirmation: "arm") }
        } message: { Text("此操作可能将设备强度设置为 1，并开始播放波形。") }
        .confirmationDialog("连接 DG-LAB 设备？", isPresented: $confirmConnect) {
            Button("连接并初始化归零") { model.command("device.connect", confirmation: "connect") }
        } message: { Text("将进行蓝牙连接并尝试发送归零指令。") }
        .confirmationDialog("停止并断开设备？", isPresented: $confirmDisconnect) {
            Button("停止会话并断开") { model.command("session.disconnect") }
        } message: { Text("将尝试停止输出、归零并断开蓝牙。") }
    }
}

private struct ChannelsPage: View {
    var body: some View {
        Text("A / B 通道").font(.largeTitle.bold())
        Text("强度按钮须在已授权会话中操作。自动提升各通道独立，每次自动 +1，累计增加指定次数或达到上限后停止。")
            .font(.caption).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 14) {
            ChannelCard(channel: "A")
            ChannelCard(channel: "B")
        }
    }
}

private struct ChannelCard: View {
    @EnvironmentObject private var model: ConsoleModel
    let channel: String
    @State private var frequencySeconds = 3
    @State private var maxIncrease = 10
    @State private var waveform = "imported_0"

    private var isActive: Bool { model.snapshot?.isActive == true }
    private var strength: Int { channel == "A" ? model.snapshot?.strengthA ?? 0 : model.snapshot?.strengthB ?? 0 }
    private var isRamping: Bool { channel == "A" ? model.snapshot?.rampA == true : model.snapshot?.rampB == true }
    private var progress: Int { channel == "A" ? model.snapshot?.rampDoneA ?? 0 : model.snapshot?.rampDoneB ?? 0 }
    private var rampTarget: Int { channel == "A" ? model.snapshot?.rampMaxA ?? maxIncrease : model.snapshot?.rampMaxB ?? maxIncrease }

    var body: some View {
        GroupBox("\(channel) 通道") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("强度").font(.headline)
                    Spacer()
                    Text("\(strength)").font(.title.bold()).monospacedDigit()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach([-5, -3, -1, 1, 3, 5], id: \.self) { delta in
                        Button(delta > 0 ? "+\(delta)" : "\(delta)") {
                            model.command("owner.delta", payload: ["channel": channel, "delta": delta])
                        }.disabled(!isActive)
                    }
                }
                HStack {
                    Picker("波形", selection: $waveform) {
                        ForEach(waveforms, id: \.id) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    Button("应用") {
                        model.command("owner.waveform", payload: ["channel": channel, "waveformId": waveform])
                    }.disabled(!isActive)
                }
                Divider()
                HStack {
                    Text("提升间隔")
                    Spacer()
                    Text("\(frequencySeconds) 秒").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(frequencySeconds) }, set: { frequencySeconds = Int($0) }),
                       in: 1...60, step: 1, onEditingChanged: { isEditing in
                    if !isEditing { model.command("ramp.rate", payload: ["channel": channel, "rateSeconds": frequencySeconds]) }
                })
                HStack {
                    Text("累计增加后停止")
                    Spacer()
                    Text("+\(maxIncrease)").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(maxIncrease) }, set: { maxIncrease = Int($0) }),
                       in: 1...33, step: 1, onEditingChanged: { isEditing in
                    if !isEditing { model.command("ramp.maxIncrease", payload: ["channel": channel, "maxIncrease": maxIncrease]) }
                })
                if isRamping {
                    Button("停止 \(channel) 自动提升") {
                        model.command("ramp.toggle", payload: ["channel": channel])
                    }.buttonStyle(.bordered).disabled(!isActive)
                } else {
                    Button("开启 \(channel) 自动提升") {
                        model.command("ramp.toggle", payload: ["channel": channel])
                    }.buttonStyle(.borderedProminent).disabled(!isActive)
                }
                Text("本轮已自动 +\(progress) / +\(rampTarget)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
        .onAppear { syncFromSnapshot() }
        .onChange(of: model.snapshot?.rampRateA) { _, _ in if channel == "A" { syncFromSnapshot() } }
        .onChange(of: model.snapshot?.rampRateB) { _, _ in if channel == "B" { syncFromSnapshot() } }
        .onChange(of: model.snapshot?.rampMaxA) { _, _ in if channel == "A" { syncFromSnapshot() } }
        .onChange(of: model.snapshot?.rampMaxB) { _, _ in if channel == "B" { syncFromSnapshot() } }
    }
    private func syncFromSnapshot() {
        guard let state = model.snapshot else { return }
        frequencySeconds = channel == "A" ? state.rampRateA ?? 3 : state.rampRateB ?? 3
        maxIncrease = channel == "A" ? state.rampMaxA ?? 10 : state.rampMaxB ?? 10
    }
}

private struct AudioPage: View {
    @EnvironmentObject private var model: ConsoleModel
    @State private var target = "both"
    @State private var low = 5
    @State private var high = 88

    private var active: Bool { model.snapshot?.isActive == true }
    var body: some View {
        Text("声音响应").font(.largeTitle.bold())
        GroupBox("macOS 系统音频") {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Button(model.snapshot?.audioVolume == true ? "关闭音量响应" : "开启音量响应") {
                        model.command("audio.volume")
                    }.disabled(!active)
                    Button(model.snapshot?.audioBeat == true ? "关闭节拍响应" : "开启节拍响应") {
                        model.command("audio.beat")
                    }.disabled(!active)
                    Button("全部关闭") { model.command("audio.off") }
                        .disabled(!model.connected)
                }
                HStack {
                    Text("响应通道")
                    Picker("", selection: $target) {
                        Text("A+B").tag("both")
                        Text("A").tag("A")
                        Text("B").tag("B")
                    }.labelsHidden().frame(width: 120)
                    Button("应用通道") { model.command("audio.target", payload: ["target": target]) }
                    Spacer()
                }
                Text("音频通过 ScreenCaptureKit 分析系统 RMS。必须在 macOS 隐私设置中给予屏幕与系统音频录制权限，不保存原始音频。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("节拍波形频率") {
            VStack(alignment: .leading, spacing: 13) {
                Text("常用固定频率")
                HStack {
                    ForEach([1, 20, 50, 100], id: \.self) { hz in
                        Button("固定 \(hz) Hz") { model.command("audio.range", payload: ["minHz": hz, "maxHz": hz]) }
                    }
                }
                Text("常用区间")
                HStack {
                    ForEach(["5–15", "10–30", "20–50", "1–100"], id: \.self) { title in
                        Button("\(title) Hz") {
                            let parts = title.components(separatedBy: "–").compactMap(Int.init)
                            if parts.count == 2 { model.command("audio.range", payload: ["minHz": parts[0], "maxHz": parts[1]]) }
                        }
                    }
                }
                Divider()
                HStack { Text("自定义下限"); Spacer(); Text("\(low) Hz").monospacedDigit() }
                Slider(value: Binding(get: { Double(low) }, set: { low = min(high, Int($0)) }), in: 1...100, step: 1)
                HStack { Text("自定义上限"); Spacer(); Text("\(high) Hz").monospacedDigit() }
                Slider(value: Binding(get: { Double(high) }, set: { high = max(low, Int($0)) }), in: 1...100, step: 1)
                HStack {
                    Button("应用 \(low)–\(high) Hz") {
                        model.command("audio.range", payload: ["minHz": low, "maxHz": high])
                    }.buttonStyle(.borderedProminent)
                    Spacer()
                    Text("正在使用：\(model.snapshot?.audioMinHz ?? 1)–\(model.snapshot?.audioMaxHz ?? 100) Hz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("这里是波形周期频率，不是声音音调，也不是电流强度。固定频率不会随鼓点变化。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .onAppear {
            target = model.snapshot?.audioTarget ?? "both"
            low = model.snapshot?.audioMinHz ?? 5
            high = model.snapshot?.audioMaxHz ?? 88
        }
    }
}

private struct TelegramPage: View {
    @EnvironmentObject private var model: ConsoleModel
    @State private var groupID = ""
    @State private var actionPool = "all"
    @State private var voteChannel = "A"
    @State private var voteWave = "imported_0"

    var body: some View {
        Text("Telegram 与直播活动").font(.largeTitle.bold())
        GroupBox("多人会话") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("参与人数：\(model.snapshot?.participants ?? 0)")
                    Spacer()
                    Text("当前模式：\(model.snapshot?.mode ?? "未启动")")
                }
                HStack {
                    Text("邀请码：\(model.snapshot?.inviteCode ?? "--")")
                        .font(.body.monospaced())
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.snapshot?.inviteCode ?? "", forType: .string) }
                    Button("查看邀请信息") { model.command("session.invite") }
                }
                HStack {
                    Button("管理员加入会话") { model.command("session.join") }
                    Button("加入临时操作队列") { model.command("event.queue") }
                    Button("退出队列") { model.command("event.queue.leave") }
                    Button("随机抽取操作员") { model.command("event.random") }
                }.disabled(!model.connected)
                Text("当前操作人员：\((model.snapshot?.operators ?? []).joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("群聊和动作池") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Telegram 目标群 ID", text: $groupID).frame(width: 240)
                    Button("绑定群聊") {
                        if let id = Int64(groupID), id < 0 { model.command("group.bind", payload: ["groupId": id]) }
                        else { model.errorMessage = "群 ID 必须是负整数" }
                    }
                    Text("已绑定：\(model.snapshot?.groupId.map(String.init) ?? "无")")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Picker("动作池", selection: $actionPool) {
                        Text("全部").tag("all")
                        Text("温和").tag("gentle")
                        Text("仅强度").tag("strength")
                        Text("仅波形").tag("waveform")
                    }.frame(width: 240)
                    Button("应用") { model.command("event.pool", payload: ["preset": actionPool]) }
                }
            }.padding(10)
        }
        GroupBox("投票操作") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("投票通道", selection: $voteChannel) {
                    Text("A").tag("A"); Text("B").tag("B")
                }.pickerStyle(.segmented).frame(width: 190)
                HStack {
                    ForEach([-5, -3, -1, 1, 3, 5], id: \.self) { delta in
                        Button(delta > 0 ? "+\(delta)" : "\(delta)") {
                            model.command("vote.submit", payload: ["channel": voteChannel,
                                "type": "strength_delta", "delta": delta])
                        }
                    }
                }
                HStack {
                    Picker("波形投票", selection: $voteWave) {
                        ForEach(waveforms, id: \.id) { item in Text(item.name).tag(item.id) }
                    }.frame(width: 250)
                    Button("提交波形投票") {
                        model.command("vote.submit", payload: ["channel": voteChannel,
                            "type": "waveform", "waveformId": voteWave])
                    }
                }
                Text("Telegram 群成员身份、实际投票结算与直播操作队列由 Bot 端处理。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .onAppear { actionPool = model.snapshot?.eventPool ?? "all" }
    }
}

private struct APIPage: View {
    @EnvironmentObject private var model: ConsoleModel
    @State private var commandName = "status"
    @State private var json = "{}"
    @State private var confirmDanger = false
    @State private var confirmRestart = false
    @State private var confirmStopService = false

    private let commands = [
        "status", "device.status", "device.connect", "session.create", "session.arm",
        "session.stop", "session.disconnect", "session.invite", "session.join",
        "owner.delta", "owner.waveform", "ramp.rate", "ramp.maxIncrease", "ramp.toggle",
        "audio.volume", "audio.beat", "audio.off", "audio.target", "audio.range",
        "group.bind", "vote.submit", "event.queue", "event.queue.leave", "event.random", "event.pool"
    ]

    var body: some View {
        Text("API 与服务").font(.largeTitle.bold())
        GroupBox("后台 Telegram Bot") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.serviceLabel, systemImage: "server.rack")
                    Spacer()
                    Button("检查状态") { Task { await model.refreshServiceStatus() } }
                }
                HStack {
                    Button("启动后台") { model.manageService("start") }
                    Button("安全重启") { confirmRestart = true }
                        .disabled(model.snapshot?.safeToRestart != true)
                    Button("停止后台") { confirmStopService = true }
                        .disabled(model.snapshot?.safeToRestart != true)
                }
                Text("重启与停止前会重新读取真实设备和会话强度。若 API 失联或状态不确定，将拒绝操作。启动/停止的是现有 LaunchAgent，不会再启动第二个 Telegram Bot。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("本地 API · 仅 127.0.0.1") {
            VStack(alignment: .leading, spacing: 11) {
                LabeledContent("API 地址", value: model.localAPIBase)
                HStack {
                    Stepper("端口：\(model.apiPort)", value: $model.apiPort, in: 1024...65535)
                        .frame(width: 210)
                    Text("默认 8789；修改端口后，后台的 DG_LOCAL_API_PORT 也必须相同。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    SecureField("输入桥接密钥（不显示）", text: $model.enteredKey)
                    Button("保存到钥匙串") { model.saveKey() }
                }
                Label(model.keyPresent ? "已配置本地 API 凭证" : "尚未取得本地 API 凭证", systemImage: model.keyPresent ? "lock.shield" : "lock.open")
                    .foregroundStyle(model.keyPresent ? .green : .orange)
                HStack {
                    Text("GET /health · GET /v1/status · GET /v1/capabilities · POST /v1/command")
                        .font(.caption.monospaced())
                    Spacer()
                    Button("复制 curl 示例") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.generatedCurlExample, forType: .string)
                    }
                }
                Text("请求需要 Authorization: Bearer <独立密钥>。设备连接需 X-DGLab-Confirm: connect；会话授权需 X-DGLab-Confirm: arm。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("高级 API 调用") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Picker("命令", selection: $commandName) {
                        ForEach(commands, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 330)
                    Spacer()
                    Button("发送 API 命令") {
                        if commandName == "session.arm" || commandName == "device.connect" { confirmDanger = true }
                        else { sendCommand() }
                    }
                    .disabled(!model.connected)
                }
                Text("JSON payload（例如 {\"channel\":\"A\",\"delta\":1}）")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $json)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 85, maxHeight: 125)
                    .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                Text("只允许服务端固定的命令白名单；不会执行任意 Shell 指令。修改设备参数前请确保有物理停止手段。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox("最近操作") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.log.prefix(10)), id: \.self) { line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .confirmationDialog("确认执行可能涉及真实设备的操作？", isPresented: $confirmDanger) {
            Button("我确认现场设备准备就绪") { sendCommand() }
        } message: { Text("连接或授权操作可能导致设备开始输出；请确认实体停止方式可立即使用。") }
        .confirmationDialog("安全重启 Bot 服务？", isPresented: $confirmRestart) {
            Button("确认重启") { model.manageService("restart") }
        } message: { Text("应用将再次向后台核查活动会话和 A/B 输出；只有确定全部归零时才允许重启。") }
        .confirmationDialog("停止 Bot 服务？", isPresented: $confirmStopService) {
            Button("确认停止后台") { model.manageService("stop") }
        } message: { Text("只有在会话和设备输出均为零时才允许停止后台。") }
    }

    private func sendCommand() {
        guard let bytes = json.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            model.errorMessage = "请求参数必须是 JSON 对象"
            return
        }
        let confirm = commandName == "session.arm" ? "arm" : commandName == "device.connect" ? "connect" : nil
        model.command(commandName, payload: payload, confirmation: confirm)
    }
}
