import Foundation
import AppKit

/// Owns the complete embedded Node/Telegram/BLE engine. There is no LaunchAgent
/// and no dependency on Homebrew's node once the app bundle is installed.
@MainActor
final class EmbeddedEngine {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stopping = false

    var running: Bool { process?.isRunning == true }

    private var appRoot: URL { Bundle.main.bundleURL }
    private var nodeURL: URL { appRoot.appendingPathComponent("Contents/Helpers/node") }
    private var helperURL: URL { appRoot.appendingPathComponent("Contents/Helpers/dglab-system-audio-meter") }
    private var engineURL: URL { appRoot.appendingPathComponent("Contents/Resources/Engine/dist/src/index.js") }

    private func appSupport() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DG-LAB Console", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isOccupied(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return true }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.8
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        return (try? await URLSession(configuration: config).data(for: request)) != nil
    }

    func start(model: ConsoleModel, diagnosticMock: Bool = false) async {
        guard !running else { model.serviceLabel = "内置引擎：已运行"; return }
        guard !(await isOccupied(port: model.apiPort)),
              !(await isOccupied(port: 8787)),
              !(await isOccupied(port: 8788)) else {
            model.errorMessage = "检测到其他 DG-LAB 控制器或端口被占用。请先关闭旧服务，避免重复 Telegram 轮询或双重蓝牙连接。"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: engineURL.path),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            model.errorMessage = "App 缺少内置 Node 引擎或系统音频助手，请安装完整的独立发行包。"
            return
        }
        let bridgeToken = model.bridgeSecret()
        guard bridgeToken.count >= 32 else { model.errorMessage = "本地桥接密钥无效"; return }
        guard model.selectedDeviceMode == "mock" || model.selectedDeviceMode == "ble" || model.selectedDeviceMode == "ios" else {
            model.errorMessage = "无效设备模式"; return
        }
        let token = model.telegramSecret()
        if model.telegramEnabled && !diagnosticMock {
            guard token?.range(of: #"^\d{6,15}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil else {
                model.errorMessage = "启用 Telegram 需要有效 Bot Token。请先在引擎与权限页导入或填写。"
                return
            }
            guard Int(model.ownerUserID) != nil else { model.errorMessage = "请先填写 Telegram 管理员数字 ID"; return }
        }
        do {
            let root = try appSupport()
            let child = Process()
            child.executableURL = nodeURL
            child.arguments = [engineURL.path]
            child.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            for key in ["NODE_OPTIONS", "NODE_PATH", "DYLD_INSERT_LIBRARIES", "TG_BOT_TOKEN", "IOS_BRIDGE_TOKEN", "DG_DEVICE_MODE"] { env.removeValue(forKey: key) }
            let telegram = model.telegramEnabled && !diagnosticMock
            env["TG_BOT_TOKEN"] = telegram ? (token ?? "") : "123456:LOCAL_TEST_TOKEN_NEVER_USED"
            env["TG_OWNER_USER_ID"] = telegram ? model.ownerUserID : "1"
            env["TG_ALLOWED_CHAT_ID"] = telegram ? (model.allowedChatID.isEmpty ? model.ownerUserID : model.allowedChatID) : "1"
            env["DG_DESKTOP_OFFLINE"] = telegram ? "0" : "1"
            env["DG_DEVICE_MODE"] = diagnosticMock ? "mock" : model.selectedDeviceMode
            env["IOS_BRIDGE_TOKEN"] = bridgeToken
            env["IOS_BRIDGE_HOST"] = diagnosticMock ? "127.0.0.1" : model.bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
            env["IOS_BRIDGE_PORT"] = "8788"
            env["DG_LOCAL_API_PORT"] = String(model.apiPort)
            env["DG_OBS_HOST"] = "127.0.0.1"
            env["DG_OBS_PORT"] = "8787"
            env["DGLAB_AUDIO_HELPER_PATH"] = helperURL.path
            env["DGLAB_CONFIG_FILE"] = root.appendingPathComponent("config.json").path
            env["DG_DESKTOP_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            // Applications brought from another computer must not import a live
            // project config file or change its device mode unexpectedly.
            child.environment = env
            let stdout = Pipe(), stderr = Pipe()
            child.standardOutput = stdout
            child.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak model] handle in
                let chunk = handle.availableData
                if !chunk.isEmpty, let line = String(data: chunk, encoding: .utf8) {
                    Task { @MainActor in model?.appendEngineMessage(line) }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak model] handle in
                let chunk = handle.availableData
                if !chunk.isEmpty, let line = String(data: chunk, encoding: .utf8) {
                    Task { @MainActor in model?.appendEngineMessage("引擎：" + line) }
                }
            }
            child.terminationHandler = { [weak self, weak model] task in
                Task { @MainActor in
                    guard let self else { return }
                    self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                    self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                    self.stdoutPipe = nil; self.stderrPipe = nil
                    if self.process === task { self.process = nil }
                    self.stopping = false
                    model?.serviceLabel = "内置引擎：已停止（退出码 \(task.terminationStatus)）"
                    await model?.refresh()
                }
            }
            try child.run()
            stdoutPipe = stdout; stderrPipe = stderr
            process = child
            model.serviceLabel = "内置引擎：启动中（PID \(child.processIdentifier)）"
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 450_000_000)
                await model.refresh()
                if model.connected { model.serviceLabel = "内置引擎：运行中（PID \(child.processIdentifier)）"; break }
                if !child.isRunning { break }
            }
            if !model.connected { model.errorMessage = "内置引擎未提供 API。请查看下方日志，检查 Telegram 凭证与端口。" }
        } catch { model.errorMessage = "无法启动内置引擎：\(error.localizedDescription)" }
    }

    func stop(model: ConsoleModel) async {
        guard let child = process, child.isRunning else { model.serviceLabel = "内置引擎：已停止"; return }
        guard !stopping else { return }
        stopping = true
        do {
            // A fresh read from the real engine is mandatory: never trust stale UI.
            let fresh = try await model.fetchSnapshot()
            guard fresh.safeToRestart else {
                throw NSError(domain: "DG-LAB", code: 423,
                    userInfo: [NSLocalizedDescriptionKey: "设备或会话仍有输出，先点击立即停止并确认 A/B 双通道均归零。"])
            }
            child.interrupt() // existing Node SIGINT shutdown performs stop / disconnect
            model.serviceLabel = "内置引擎：安全停止中"
        } catch {
            model.errorMessage = "拒绝停止引擎：\(error.localizedDescription)"
        }
        stopping = false
    }

    func mayQuit(model: ConsoleModel) -> Bool {
        if !running { return true }
        guard model.snapshot?.safeToRestart == true else { return false }
        // Quit is guarded against active output in AppDelegate; backend receives
        // SIGINT. Its watchdog also checks that the owning GUI stays alive.
        process?.interrupt()
        return true
    }
}
