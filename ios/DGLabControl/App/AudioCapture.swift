import Foundation
import Combine
import AVFoundation
import DGLabCore

/// Explicit, privacy-preserving audio input: microphone or audio played inside this app.
/// iOS does not provide automatic cross-app system-output capture via AVAudioEngine.
@MainActor
final class AudioCapture: ObservableObject {
    @Published var source: AudioInputSource = .microphone
    @Published private(set) var rms: Double = 0
    @Published private(set) var isRunning = false
    @Published var status: String = "声控未开启"
    @Published var selectedFileName = "未选择音频"
    var onMetric: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var currentFile: URL?
    private var watchdog: Timer?
    private var lastSample = Date.distantPast
    private var hasInputTap = false
    private var hasMixerTap = false

    func importFile(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dglab-audio-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            if let previous = currentFile { try? FileManager.default.removeItem(at: previous) }
            currentFile = dest
            selectedFileName = url.lastPathComponent
        } catch { status = "读取音频失败：\(error.localizedDescription)" }
    }
    func start() async throws {
        stop()
        if source == .mbpAudio {
            isRunning = true; status = "等待 MBP 音频指标"
            beginWatchdog(); return
        }
        let engine = AVAudioEngine()
        let session = AVAudioSession.sharedInstance()
        if source == .microphone {
            let granted: Bool = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw DGControlError.noPermission }
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            try input.__installTap(onBus: 0, bufferSize: 1024, format: format, error: ()) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            hasInputTap = true
        } else {
            guard let currentFile else { throw DGControlError.noPermission }
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let file = try AVAudioFile(forReading: currentFile)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            try engine.connectNode(player, to: engine.mainMixerNode, format: file.processingFormat)
            let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            try engine.mainMixerNode.__installTap(onBus: 0, bufferSize: 1024, format: outputFormat, error: ()) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            hasMixerTap = true
            await player.scheduleFile(file, at: nil)
            self.player = player
        }
        try engine.start()
        self.engine = engine
        try player?.playAudio()
        lastSample = Date()
        isRunning = true
        status = source == .microphone ? "麦克风响度分析中（不录音存档）" : "App 正在播放并分析音频"
        beginWatchdog()
    }
    func injectRemoteMetric(_ value: Double) {
        guard source == .mbpAudio, isRunning else { return }
        acceptMetric(value)
    }
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        guard length > 0, count > 0 else { return }
        var sum = 0.0
        for c in 0..<count {
            for i in 0..<length { let value = Double(channels[c][i]); sum += value * value }
        }
        let level = min(1.0, sqrt(sum / Double(length * count)))
        DispatchQueue.main.async { [weak self] in self?.acceptMetric(level) }
    }
    private func acceptMetric(_ value: Double) {
        guard isRunning, value.isFinite, (0...1).contains(value) else { return }
        rms = value
        lastSample = Date()
        onMetric?(value)
    }
    private func beginWatchdog() {
        lastSample = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if Date().timeIntervalSince(self.lastSample) > 5 {
                    self.onFailure?("超过五秒没有音频数据，声控已停止")
                    self.stop()
                }
            }
        }
    }
    func stop() {
        watchdog?.invalidate(); watchdog = nil
        player?.stop(); player = nil
        if hasInputTap { engine?.inputNode.removeTap(onBus: 0); hasInputTap = false }
        if hasMixerTap { engine?.mainMixerNode.removeTap(onBus: 0); hasMixerTap = false }
        engine?.stop(); engine = nil
        if isRunning { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        isRunning = false; rms = 0
        status = "声控未开启"
    }
}
