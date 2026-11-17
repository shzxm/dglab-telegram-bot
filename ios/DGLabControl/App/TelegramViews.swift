import SwiftUI
import WebKit
import DGLabCore

struct TelegramPage: View {
    @EnvironmentObject private var c: DGLabController
    @State private var secret = RelayCredentials.load()
    @AppStorage("telegramBotUsername") private var botUsername = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Telegram Bot 桥接").font(.title2.bold()); Spacer();
                        StatusChip(text: c.bridge.connected ? "已连接" : "未连接", online: c.bridge.connected) }
                    Text("Bot Token 仅保留在 MBP。手机使用另一份桥接凭证，不会与现有 Bot 争抢 Telegram getUpdates。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("ws://192.168.1.x:8788（局域网）", text: Binding(get: { c.bridge.endpoint }, set: { c.bridge.endpoint = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL).keyboardType(.URL)
                    SecureField("独立桥接密钥（不是 Bot Token）", text: $secret)
                    HStack {
                        Button("作为蓝牙主机连接") { connect(.host) }.buttonStyle(.borderedProminent)
                        Button("远程控制 Bot") { connect(.remote) }.buttonStyle(.bordered)
                    }.font(.caption)
                    if c.bridge.connected { Button("断开桥接") { c.bridge.disconnect() }.tint(.red) }
                    Text(c.bridge.connectionLabel).font(.caption).foregroundStyle(.secondary)
                }.dgCard()
                if c.bridge.connected { remoteActions }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Telegram Bot 快捷入口").font(.headline)
                    TextField("Bot 用户名，不含 @", text: $botUsername)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !botUsername.trimmingCharacters(in: .whitespaces).isEmpty,
                       let url = URL(string: "https://t.me/\(botUsername.replacingOccurrences(of: "@", with: ""))") {
                        Link(destination: url) { Label("打开 Telegram Bot", systemImage: "paperplane.fill") }
                    }
                    Text("多人邀请码、群绑定、投票与临时操作员由现有 Bot 负责；iPhone 负责界面和（主机模式下）蓝牙。")
                        .font(.caption).foregroundStyle(.secondary)
                }.dgCard()
            }.padding(16)
        }.navigationTitle("Telegram")
    }
    private func connect(_ role: ControlRole) {
        c.selectRole(role)
        do { try c.bridge.connect(role: role, token: secret) }
        catch { c.reportError(error) }
    }
    private var remoteActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text("会话同步").font(.headline)
                LabeledContent("状态", value: c.bridge.relayStatus.active ? "进行中" : "未开启")
                LabeledContent("参与者", value: "\(c.bridge.relayStatus.participants)")
                LabeledContent("A / B", value: "\(c.bridge.relayStatus.strengthA) / \(c.bridge.relayStatus.strengthB)")
                LabeledContent("操作人员", value: c.bridge.relayStatus.operators.joined(separator: "、"))
                if !c.bridge.relayStatus.inviteCode.isEmpty {
                    HStack { Text("邀请码：\(c.bridge.relayStatus.inviteCode)").font(.subheadline.monospaced());
                        Spacer()
                        Button { UIPasteboard.general.string = c.bridge.relayStatus.inviteCode } label: { Image(systemName: "doc.on.doc") }
                    }
                }
                HStack {
                    Button("刷新状态") { c.requestBot("status") }
                    Button("查看邀请码") { c.requestBot("session.invite") }
                }.buttonStyle(.bordered)
            }.dgCard()
            VStack(alignment: .leading, spacing: 10) {
                Text("多人投票与活动").font(.headline)
                HStack {
                    Button("加入会话") { c.requestBot("session.join", payload: ["inviteCode": c.joinCode]) }
                    Button("加入10秒队列") { c.requestBot("event.queue") }
                }.buttonStyle(.bordered)
                TextField("邀请码", text: $c.joinCode).textInputAutocapitalization(.characters)
                HStack {
                    Button("随机操作员") { c.requestBot("event.random") }
                    Button("退出队列") { c.requestBot("event.queue.leave") }
                }.buttonStyle(.bordered)
                Picker("动作池", selection: $c.actionPool) {
                    ForEach(DGLabController.actionPools.indices, id: \.self) { index in
                        Text(DGLabController.actionPools[index].1).tag(DGLabController.actionPools[index].0)
                    }
                }.pickerStyle(.segmented)
                    .onChange(of: c.actionPool) { _, value in c.requestBot("event.pool", payload: ["preset": value]) }
                TextField("Telegram 群 ID", text: $c.groupID).keyboardType(.numbersAndPunctuation)
                Button("绑定当前群聊并发布面板") {
                    if let id = Int64(c.groupID) { c.requestBot("group.bind", payload: ["groupId": id]) }
                    else { c.reportError(DGControlError.rejected) }
                }.buttonStyle(.bordered)
            }.dgCard()
            VStack(alignment: .leading, spacing: 10) {
                Text("投票（A/B 强度与波形分别计票）").font(.headline)
                ForEach(DGChannel.allCases) { channel in
                    HStack {
                        Text(channel.rawValue).font(.headline)
                        ForEach([-3, -1, 1, 3], id: \.self) { delta in
                            Button(delta > 0 ? "+\(delta)" : "\(delta)") {
                                c.requestBot("vote.submit", payload: ["channel": channel.rawValue, "type": "strength_delta", "delta": delta])
                            }.buttonStyle(.bordered).font(.caption)
                        }
                    }
                    Menu("\(channel.rawValue) 通道波形投票") {
                        ForEach(BuiltinWaveforms.all) { preset in
                            Button(preset.name) {
                                c.requestBot("vote.submit", payload: ["channel": channel.rawValue, "type": "waveform", "waveformId": preset.id])
                            }
                        }
                    }
                    ForEach(c.bridge.relayStatus.votes.keys.sorted(), id: \.self) { key in
                        if key.hasPrefix("\(channel.rawValue):") {
                            LabeledContent(key, value: "\(c.bridge.relayStatus.votes[key] ?? 0) 票")
                                .font(.caption)
                        }
                    }
                }
            }.dgCard()
            EmergencyButton()
            if !c.bridge.lastMessage.isEmpty { Text(c.bridge.lastMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject private var c: DGLabController
    @AppStorage("dglabOBSURL") private var obsURL = ""
    @State private var confirmAdvanced = false
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("安全设置").font(.title2.bold())
                    Toggle("高级强度上限（最多 133）", isOn: Binding(get: { c.allowAdvancedCap }, set: { value in
                        if value { confirmAdvanced = true } else {
                            c.allowAdvancedCap = false
                            c.capA = min(c.capA, 30); c.capB = min(c.capB, 30)
                        }
                    })).disabled(c.active)
                    Text("软件上限 133 不是医学安全阈值。默认本地上限必须自行设置，超过 30 需要额外确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("强制停止：如果 BLE 断开、App 进入后台、会话到期或声音采集失败，发送归零并取消自动操作。物理硬件仍需手边有独立停止手段。")
                        .font(.caption).foregroundStyle(.secondary)
                }.dgCard()
                VStack(alignment: .leading, spacing: 10) {
                    Text("OBS 叠加层").font(.headline)
                    TextField("https://你的服务/obs", text: $obsURL).textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let url = URL(string: obsURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        Link("打开叠加层", destination: url)
                    }
                    Text("OBS 画面继续由现有 Bot 提供；App 可以查看其地址，但不会自动把 localhost 暴露到公网。")
                        .font(.caption).foregroundStyle(.secondary)
                }.dgCard()
                VStack(alignment: .leading, spacing: 10) {
                    Text("药时 · PK Atlas 跨应用入口").font(.headline)
                    Button("打开药时（只切换 App）") {
                        // No medicine information is exchanged.
                        if let url = URL(string: "pkatlas://open?source=dglab") {
                            openURL(url)
                        }
                    }
                    Text("仅打开独立的药代记录应用；不会读取服药资料，也不会依据药代结果启动设备。")
                        .font(.caption).foregroundStyle(.secondary)
                }.dgCard()
                VStack(alignment: .leading, spacing: 8) {
                    Text("日志（不包含 Token 或原始音频）").font(.headline)
                    ForEach(c.log.prefix(18), id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }.dgCard()
                VStack(alignment: .leading, spacing: 8) {
                    Text("关于").font(.headline)
                    Text("DG-LAB iOS · 原生 SwiftUI · iOS 27 SDK")
                    Text("支持独立蓝牙主机 / Telegram 桥接两种角色。无法通过 Bot Token 直接占用现有轮询，不会存储聊天正文或声音。")
                        .font(.caption).foregroundStyle(.secondary)
                }.dgCard()
            }.padding(16)
        }
        .navigationTitle("设置")
        .alert("高级强度上限", isPresented: $confirmAdvanced) {
            Button("取消", role: .cancel) { c.allowAdvancedCap = false }
            Button("我理解并开启") { c.allowAdvancedCap = true }
        } message: { Text("更高强度有更高伤害风险，软件范围不能证明人体安全性；只有在会话停止时才能修改。") }
    }
}
