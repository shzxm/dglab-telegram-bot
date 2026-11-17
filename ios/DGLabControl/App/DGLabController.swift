import Foundation
import SwiftUI
import Combine
import DGLabCore

@MainActor
final class DGLabController: ObservableObject {
    let ble = BLEHost()
    let sound = AudioCapture()
    let bridge = TelegramRelay()
    private let safety = SessionSafetyEngine()
    private var meter = AudioFeatureMapper()
    private var sessionClock: Timer?
    private var rampTimers: [DGChannel: Timer] = [:]
    private var rampBudgets: [DGChannel: RampBudget] = [:]
    private var observations: Set<AnyCancellable> = []
    private var pendingHostConsent: CheckedContinuation<[String: Any], Error>?

    @Published var role: ControlRole = .standalone
    @Published var mode: SessionMode = .collaboration
    @Published var capA = 0
    @Published var capB = 0
    @Published var allowAdvancedCap = false
    @Published var sessionSeconds = 9999
    @Published var sessionStarted = false
    @Published var waveA = "imported_0"
    @Published var waveB = "imported_0"
    @Published var rampA = false
    @Published var rampB = false
    @Published var rateA = 3
    @Published var rateB = 3
    @Published var rampMaxA = 10
    @Published var rampMaxB = 10
    @Published var rampDoneA = 0
    @Published var rampDoneB = 0
    @Published var customLowHz = 5
    @Published var customHighHz = 88
    @Published var usingCustomFrequency = false
    @Published var volumeEnabled = false
    @Published var beatEnabled = false
    @Published var audioTarget = "A+B"
    @Published var frequency = AudioFrequencyRange.presets[0]
    @Published var log: [String] = ["未授权连接时，所有通道保持零输出"]
    @Published var errorMessage: String?
    @Published var hostApprovalNeeded = false
    @Published var actionPool = "all"
    @Published var groupID = ""
    @Published var joinCode = ""

    static let actionPools = [("all", "全部"), ("gentle", "温和"), ("strength", "仅强度"), ("waveform", "仅波形")]
    var active: Bool { role == .remote ? bridge.relayStatus.active : sessionStarted }
    var strengthA: Int { role == .remote ? bridge.relayStatus.strengthA : ble.strengthA }
    var strengthB: Int { role == .remote ? bridge.relayStatus.strengthB : ble.strengthB }
    func rampIsRunning(_ channel: DGChannel) -> Bool {
        if role == .remote { return channel == .A ? bridge.relayStatus.rampA : bridge.relayStatus.rampB }
        return rampTimers[channel] != nil
    }
    func rampCompleted(_ channel: DGChannel) -> Int {
        if role == .remote { return channel == .A ? bridge.relayStatus.rampDoneA : bridge.relayStatus.rampDoneB }
        return channel == .A ? rampDoneA : rampDoneB
    }
    var timeRemaining: Int {
        guard let date = safety.expiresAt, sessionStarted else { return 0 }
        return max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
    }

    init() {
        for publisher in [ble.objectWillChange, sound.objectWillChange, bridge.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        ble.onUnexpectedDisconnect = { [weak self] in self?.stopLocal(reason: "蓝牙意外断开，已终止会话") }
        sound.onMetric = { [weak self] level in self?.applyAudioMetric(level) }
        sound.onFailure = { [weak self] msg in self?.stopLocal(reason: msg) }
        bridge.onRemoteAudioMetric = { [weak self] value in self?.sound.injectRemoteMetric(value) }
        bridge.onHostDisconnected = { [weak self] in self?.stopLocal(reason: "Telegram 桥接断开") }
        bridge.onHostInstruction = { [weak self] command, parameters in
            guard let self else { throw DGControlError.relayDisconnected }
            return try await self.handleHostCommand(command, parameters: parameters)
        }
    }
    func report(_ message: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(message)", at: 0)
        if log.count > 120 { log = Array(log.prefix(120)) }
    }
    func reportError(_ error: Error) { errorMessage = error.localizedDescription; report(error.localizedDescription) }
    func startLocalSession() {
        do {
            guard role != .remote else { throw DGControlError.rejected }
            guard ble.connected else { throw DGControlError.notConnected }
            guard capA > 0 || capB > 0 else { throw DGControlError.invalidStrength }
            try safety.arm(maxA: capA, maxB: capB, duration: Double(sessionSeconds))
            do { try ble.armLocally() }
            catch { safety.stop(); throw error }
            sessionStarted = true
            sessionClock?.invalidate()
            sessionClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionStarted else { return }
                    do { try self.safety.verify() }
                    catch { self.stopLocal(reason: "会话时间已到") }
                    self.objectWillChange.send()
                }
            }
            report("管理员本地授权会话，A/B 上限 \(capA)/\(capB)")
        } catch { reportError(error) }
    }
    func stopLocal(reason: String = "已立即停止") {
        for timer in rampTimers.values { timer.invalidate() }
        rampTimers.removeAll()
        rampBudgets.removeAll()
        rampA = false; rampB = false
        rampDoneA = 0; rampDoneB = 0
        volumeEnabled = false; beatEnabled = false
        sound.stop()
        sessionClock?.invalidate(); sessionClock = nil
        ble.emergencyStop()
        safety.stop()
        sessionStarted = false
        if let pendingHostConsent {
            self.pendingHostConsent = nil
            pendingHostConsent.resume(throwing: DGControlError.rejected)
        }
        hostApprovalNeeded = false
        report(reason)
    }
    func emergencyStop() {
        stopLocal()
        if role == .remote, bridge.connected {
            Task { [weak self] in
                do { _ = try await self?.bridge.command("session.stop") }
                catch { self?.reportError(error) }
            }
        }
        if role == .host, bridge.connected {
            Task { [weak self] in try? await self?.bridge.command("host.stopped") }
        }
    }
    func disconnectDevice() { stopLocal(reason: "已停止并断开蓝牙"); ble.disconnect() }
    func selectRole(_ newRole: ControlRole) {
        guard role != newRole else { return }
        stopLocal(reason: "已切换控制模式，默认保持停止")
        bridge.disconnect()
        role = newRole
    }
    func changeStrength(_ channel: DGChannel, delta: Int) {
        if role == .remote {
            Task { [weak self] in
                do { _ = try await self?.bridge.command("owner.delta", payload: ["channel": channel.rawValue, "delta": delta]) }
                catch { self?.reportError(error) }
            }
            return
        }
        do {
            let values = try safety.delta(channel, delta)
            try ble.setStrength(a: values.0, b: values.1, capA: capA, capB: capB)
        } catch { reportError(error) }
    }
    func selectWave(_ id: String, channel: DGChannel) {
        if channel == .A { waveA = id } else { waveB = id }
        if role == .remote {
            Task { [weak self] in
                do { _ = try await self?.bridge.command("owner.waveform", payload: ["channel": channel.rawValue, "waveformId": id]) }
                catch { self?.reportError(error) }
            }
            return
        }
        guard sessionStarted else { return } // Selection alone never starts output.
        do { try ble.play(id, on: channel) }
        catch { reportError(error); stopLocal(reason: "播放失败，已停止") }
    }
    /// A/B sliders update the displayed value immediately, but commit their remote
    /// command once on release to avoid hitting the bridge's per-second rate limiter.
    func commitRampInterval(_ channel: DGChannel) {
        let seconds = channel == .A ? rateA : rateB
        do { try RampBudget.validateInterval(seconds) }
        catch { reportError(error); return }
        if role == .remote {
            requestBot("ramp.rate", payload: ["channel": channel.rawValue, "rateSeconds": seconds])
        } else if rampTimers[channel] != nil {
            // Reschedule without resetting the count already completed.
            scheduleRamp(channel)
        }
    }
    func commitRampMaximum(_ channel: DGChannel) {
        let maximum = channel == .A ? rampMaxA : rampMaxB
        guard RampBudget.allowedIncrease.contains(maximum) else {
            reportError(DGControlError.invalidStrength); return
        }
        if role == .remote {
            requestBot("ramp.maxIncrease", payload: ["channel": channel.rawValue, "maxIncrease": maximum])
        } else if var budget = rampBudgets[channel] {
            do {
                try budget.updateMaximum(maximum)
                rampBudgets[channel] = budget
                if budget.isComplete { stopRamp(channel, note: "已达到新的累计提升上限") }
            } catch { reportError(error) }
        }
    }
    func toggleRamp(_ channel: DGChannel) {
        if role == .remote {
            requestBot("ramp.toggle", payload: ["channel": channel.rawValue])
            return
        }
        guard sessionStarted else { reportError(DGControlError.notArmed); return }
        if rampTimers[channel] != nil { stopRamp(channel) }
        else {
            do {
                let maxIncrease = channel == .A ? rampMaxA : rampMaxB
                rampBudgets[channel] = try RampBudget(maximum: maxIncrease)
                if channel == .A { rampDoneA = 0 } else { rampDoneB = 0 }
                scheduleRamp(channel)
            } catch { reportError(error) }
        }
    }
    private func stopRamp(_ channel: DGChannel, note: String? = nil) {
        rampTimers[channel]?.invalidate()
        rampTimers[channel] = nil
        if channel == .A { rampA = false } else { rampB = false }
        if let note { report("\(channel.rawValue) 通道自动提升停止：\(note)") }
    }
    private func scheduleRamp(_ channel: DGChannel) {
        let rate = channel == .A ? rateA : rateB
        do { try RampBudget.validateInterval(rate) }
        catch { reportError(error); stopRamp(channel); return }
        rampTimers[channel]?.invalidate()
        rampTimers[channel] = Timer.scheduledTimer(withTimeInterval: Double(rate), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickRamp(channel) }
        }
        if channel == .A { rampA = true } else { rampB = true }
    }
    private func tickRamp(_ channel: DGChannel) {
        guard rampTimers[channel] != nil, sessionStarted else { stopRamp(channel); return }
        guard var budget = rampBudgets[channel] else { stopRamp(channel); return }
        let previous = channel == .A ? ble.strengthA : ble.strengthB
        let cap = channel == .A ? capA : capB
        guard !budget.isComplete, previous < cap else {
            stopRamp(channel, note: budget.isComplete ? "累计提升已完成" : "已达到通道上限")
            return
        }
        do {
            let values = try safety.delta(channel, 1)
            let next = channel == .A ? values.0 : values.1
            guard next > previous else { stopRamp(channel, note: "已达到通道上限"); return }
            try ble.setStrength(a: values.0, b: values.1, capA: capA, capB: capB)
            budget.registerSuccessfulStep()
            rampBudgets[channel] = budget
            if channel == .A { rampDoneA = budget.completed } else { rampDoneB = budget.completed }
            if budget.isComplete || next >= cap {
                stopRamp(channel, note: budget.isComplete ? "累计 +\(budget.completed) 已完成" : "已达到通道上限")
            }
        } catch {
            reportError(error)
            stopLocal(reason: "自动提升写入异常，已停止会话")
        }
    }
    func toggleAudio(_ mode: AudioResponseMode) {
        if role == .remote {
            Task { [weak self] in
                do { _ = try await self?.bridge.command(mode == .volume ? "audio.volume" : "audio.beat") }
                catch { self?.reportError(error) }
            }
            return
        }
        guard sessionStarted else { reportError(DGControlError.notArmed); return }
        if mode == .volume { volumeEnabled.toggle() } else { beatEnabled.toggle() }
        if !volumeEnabled && !beatEnabled {
            sound.stop()
            if sound.source == .mbpAudio && bridge.connected { requestBot("audio.monitor.stop") }
            ble.updateModulation(nil, channel: .A); ble.updateModulation(nil, channel: .B)
            report("声控已关闭，自动提升保持原状")
        } else {
            meter = AudioFeatureMapper()
            if !sound.isRunning {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        if self.sound.source == .mbpAudio {
                            guard self.bridge.connected else { throw DGControlError.relayDisconnected }
                            _ = try await self.bridge.command("audio.monitor.start")
                        }
                        try await self.sound.start()
                    }
                    catch { self.reportError(error); self.volumeEnabled = false; self.beatEnabled = false }
                }
            }
        }
    }
    func setFrequency(_ value: AudioFrequencyRange) {
        do { try value.validate() }
        catch { reportError(error); return }
        usingCustomFrequency = false
        frequency = value
        commitFrequency()
    }
    /// Changes from dragging are applied locally immediately. The remote bridge
    /// is only notified when the gesture ends, preventing dozens of commands/second.
    func updateCustomFrequency(low: Int, high: Int) {
        let lower = max(1, min(99, low))
        let upper = max(lower + 1, min(100, high))
        customLowHz = lower
        customHighHz = upper
        usingCustomFrequency = true
        frequency = AudioFrequencyRange(lower, upper)
    }
    func selectCustomFrequency() {
        updateCustomFrequency(low: customLowHz, high: customHighHz)
        commitFrequency()
    }
    func commitCustomFrequency() { commitFrequency() }
    private func commitFrequency() {
        guard role == .remote else { return }
        requestBot("audio.range", payload: ["minHz": frequency.minHz, "maxHz": frequency.maxHz])
    }
    private func applyAudioMetric(_ rms: Double) {
        guard sessionStarted, volumeEnabled || beatEnabled else { return }
        do {
            let value = try meter.update(rms: rms,
                                        seconds: ProcessInfo.processInfo.systemUptime,
                                        volumeEnabled: volumeEnabled, beatEnabled: beatEnabled,
                                        range: frequency)
            if audioTarget == "A+B" || audioTarget == "A" { ble.updateModulation(value, channel: .A) }
            else { ble.updateModulation(nil, channel: .A) }
            if audioTarget == "A+B" || audioTarget == "B" { ble.updateModulation(value, channel: .B) }
            else { ble.updateModulation(nil, channel: .B) }
        } catch { reportError(error); stopLocal(reason: "无效声音数据，已停止") }
    }
    func requestBot(_ command: String, payload: [String: Any] = [:]) {
        guard bridge.connected else { reportError(DGControlError.relayDisconnected); return }
        Task { [weak self] in
            do {
                let state = try await self?.bridge.command(command, payload: payload)
                if let text = state?["message"] as? String { self?.report(text) }
            } catch { self?.reportError(error) }
        }
    }
    /// All remote hardware commands are subordinate to local permission, local cap and session TTL.
    private func handleHostCommand(_ command: String, parameters: [String: Any]) async throws -> [String: Any] {
        guard role == .host, bridge.connected else { throw DGControlError.relayDisconnected }
        switch command {
        case "device.connect":
            guard ble.connected else { throw DGControlError.notConnected }
            if sessionStarted { return hostStatus() }
            guard pendingHostConsent == nil else { throw DGControlError.rejected }
            return try await withCheckedThrowingContinuation { continuation in
                pendingHostConsent = continuation
                hostApprovalNeeded = true
                report("Telegram 请求本机设备授权，等待在 iPhone 上确认")
            }
        case "device.status": return hostStatus()
        case "device.zero":
            _ = try safety.setAbsolute(a: 0, b: 0)
            try ble.zeroWhileArmed()
            return hostStatus()
        case "device.strength":
            let a = parameters["a"] as? Int ?? -1
            let b = parameters["b"] as? Int ?? -1
            let checked = try safety.setAbsolute(a: a, b: b)
            try ble.setStrength(a: checked.0, b: checked.1, capA: capA, capB: capB)
            return hostStatus()
        case "device.waveform":
            try safety.verify()
            guard let channelName = parameters["channel"] as? String,
                  let channel = DGChannel(rawValue: channelName),
                  let id = parameters["waveformId"] as? String else { throw DGControlError.rejected }
            try ble.play(id, on: channel)
            if channel == .A { waveA = id } else { waveB = id }
            return hostStatus()
        case "device.modulation":
            try safety.verify()
            guard let name = parameters["channel"] as? String,
                  let channel = DGChannel(rawValue: name) else { throw DGControlError.rejected }
            let value = WaveModulation(speedFactor: parameters["speedFactor"] as? Double,
                                       periodMilliseconds: parameters["periodMs"] as? Int)
            ble.updateModulation(value, channel: channel)
            return hostStatus()
        case "device.emergency", "device.disconnect":
            stopLocal(reason: "Telegram 请求紧急停止")
            if command == "device.disconnect" { ble.disconnect() }
            return hostStatus()
        default: throw DGControlError.rejected
        }
    }
    func approveHostControl() {
        hostApprovalNeeded = false
        guard let pending = pendingHostConsent else { return }
        pendingHostConsent = nil
        do {
            guard capA > 0 || capB > 0 else { throw DGControlError.invalidStrength }
            try safety.arm(maxA: capA, maxB: capB, duration: Double(sessionSeconds))
            try ble.armLocally()
            sessionStarted = true
            sessionClock?.invalidate()
            sessionClock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try self.safety.verify() } catch { self.stopLocal(reason: "主机会话已到期") }
                }
            }
            report("已在 iPhone 本地批准 Telegram 控制")
            pending.resume(returning: hostStatus())
        } catch { pending.resume(throwing: error); reportError(error) }
    }
    func rejectHostControl() {
        hostApprovalNeeded = false
        pendingHostConsent?.resume(throwing: DGControlError.rejected)
        pendingHostConsent = nil
        report("已拒绝远程设备授权")
    }
    private func hostStatus() -> [String: Any] {
        return ["connected": ble.connected, "armed": sessionStarted,
                "battery": ble.battery ?? 0, "strengthA": ble.strengthA,
                "strengthB": ble.strengthB, "capA": capA, "capB": capB]
    }
}
