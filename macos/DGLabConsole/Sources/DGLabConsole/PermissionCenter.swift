import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreBluetooth
import CoreGraphics
import Foundation
import UserNotifications

/// macOS owns TCC grants. These buttons ASK the OS, never modify protected
/// databases or claim permissions that cannot be read reliably.
@MainActor
final class PermissionCenter: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = PermissionCenter()
    @Published private(set) var bluetooth = "尚未触发授权"
    @Published private(set) var microphone = "未确定"
    @Published private(set) var screen = "未确定"
    @Published private(set) var systemAudio = "未测试"
    @Published private(set) var notifications = "未确定"
    @Published private(set) var accessibility = "未确定"
    @Published private(set) var audioTesting = false
    @Published var message = ""

    private var central: CBCentralManager?
    private var audioTestProcess: Process?

    func refresh() {
        switch CBManager.authorization {
        case .allowedAlways: bluetooth = "已授权"
        case .denied: bluetooth = "已拒绝，请在系统设置中启用"
        case .restricted: bluetooth = "受系统限制"
        case .notDetermined: bluetooth = "未申请"
        @unknown default: bluetooth = "系统状态未知"
        }
        if let central {
            switch central.state {
            case .poweredOn: bluetooth = "已授权，蓝牙可用"
            case .poweredOff: bluetooth = "已授权但蓝牙已关闭"
            case .unauthorized: bluetooth = "蓝牙权限未获准"
            case .unsupported: bluetooth = "此 Mac 不支持蓝牙"
            default: break
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "已授权"
        case .notDetermined: microphone = "未申请"
        case .denied: microphone = "已拒绝，请在系统设置中启用"
        case .restricted: microphone = "受系统限制"
        @unknown default: microphone = "系统状态未知"
        }
        screen = CGPreflightScreenCaptureAccess() ? "已授权录屏" : "未授权或待重启"
        accessibility = AXIsProcessTrusted() ? "已授权" : "未授权（可选）"
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional: self?.notifications = "已授权"
                case .denied: self?.notifications = "已拒绝，请在系统设置中启用"
                case .notDetermined: self?.notifications = "未申请"
                case .ephemeral: self?.notifications = "临时授权"
                @unknown default: self?.notifications = "未知"
                }
            }
        }
    }

    func requestBluetooth() {
        // Constructing CBCentralManager from this actual app identity invokes
        // the OS consent sheet if Bluetooth is not previously decided.
        if CBManager.authorization == .denied { openSettings("Privacy_Bluetooth"); return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        refresh()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { refresh() }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            openSettings("Privacy_Microphone"); return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestScreen() {
        // CGRequestScreenCaptureAccess does not promise to open System Settings
        // if permission was previously denied. Open the correct privacy pane
        // explicitly as requested, then invoke the system's consent API.
        openSettings("Privacy_ScreenCapture")
        guard !CGPreflightScreenCaptureAccess() else {
            message = "屏幕录制已授权，可在系统设置中确认。"
            refresh()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = CGRequestScreenCaptureAccess()
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func testSystemAudio() {
        guard !audioTesting else { return }
        audioTesting = true
        systemAudio = "正在请求系统音频录制权限…"
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dglab-system-audio-meter")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--permission-test"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            // Run is fast and nonblocking; retain the child synchronously so
            // AppDelegate can stop it even when the macOS TCC sheet is open.
            try process.run()
            audioTestProcess = process
        } catch {
            audioTesting = false
            systemAudio = "测试启动失败"
            message = "无法启动录音权限测试：\(error.localizedDescription)"
            return
        }
        Task.detached { [weak self] in
            process.waitUntilExit()
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let ok = process.terminationStatus == 0 && stdout.contains("permission_test_ok")
            await self?.completeAudioTest(process: process, ok: ok, errorText: ok ? "" : String(err.prefix(350)))
        }
    }

    private func completeAudioTest(process: Process, ok: Bool, errorText: String) {
        guard audioTestProcess === process else { return }
        audioTestProcess = nil
        systemAudio = ok ? "测试通过，系统音频可访问" : "未通过：请检查录屏与系统音频设置"
        if !ok { message = errorText }
        audioTesting = false
        refresh()
    }

    func stopAudioTest() {
        if let child = audioTestProcess, child.isRunning { child.terminate() }
        audioTestProcess = nil
        if audioTesting {
            audioTesting = false
            systemAudio = "已随 App 退出取消录音权限测试"
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAccessibility() {
        if AXIsProcessTrusted() { refresh(); return }
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        message = "辅助功能并非核心控制所必需，只有需要 GUI 自动化时才授权。"
        refresh()
    }

    func chooseLocalFile() {
        let panel = NSOpenPanel()
        panel.message = "选择用户允许 App 访问的文件；不会扫描其他文件夹。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { message = "已选择文件：\(panel.url?.lastPathComponent ?? "未知")" }
    }

    func openSettings(_ section: String) {
        // macOS 26+ uses the PrivacySecurity extension for deep links. The
        // older com.apple.preference.security address is retained as a
        // fallback for earlier supported macOS releases.
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(section)",
            "x-apple.systempreferences:com.apple.preference.security?\(section)"
        ]
        let opened = candidates.compactMap(URL.init(string:)).contains { NSWorkspace.shared.open($0) }
        if opened {
            message = "已打开系统设置的相关隐私权限页面。授权后返回本 App 点击刷新，必要时重启本 App。"
        } else {
            let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            _ = NSWorkspace.shared.open(app)
            message = "已尝试打开系统设置。请手动进入 隐私与安全性 → 屏幕与系统音频录制（或相应权限）。"
        }
    }
}
