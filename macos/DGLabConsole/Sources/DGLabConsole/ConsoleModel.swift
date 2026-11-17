import AppKit
import Combine
import Foundation

// Single integrated macOS app: the native UI owns an embedded Node engine.
// Both share the exact existing ControlSession, but no LaunchAgent is required.
struct ConsoleDevice: Decodable {
    var connected: Bool? = nil
    var battery: Int? = nil
    var strengthA: Int? = nil
    var strengthB: Int? = nil
}

struct ConsoleSnapshot: Decodable {
    var active: Bool? = nil
    var sessionState: String? = nil
    var mode: String? = nil
    var strengthA: Int? = nil
    var strengthB: Int? = nil
    var strengthLimit: Int? = nil
    var waveformA: String? = nil
    var waveformB: String? = nil
    var device: ConsoleDevice? = nil
    var deviceMode: String? = nil
    var participants: Int? = nil
    var inviteCode: String? = nil
    var groupId: Int64? = nil
    var eventPool: String? = nil
    var operators: [String]? = nil
    var expiresAt: Double? = nil
    var rampA: Bool? = nil
    var rampB: Bool? = nil
    var rampRateA: Int? = nil
    var rampRateB: Int? = nil
    var rampMaxA: Int? = nil
    var rampMaxB: Int? = nil
    var rampDoneA: Int? = nil
    var rampDoneB: Int? = nil
    var audioVolume: Bool? = nil
    var audioBeat: Bool? = nil
    var audioTarget: String? = nil
    var audioMinHz: Int? = nil
    var audioMaxHz: Int? = nil
    var obsURL: String? = nil
    var votes: [String: Int]? = nil

    var isActive: Bool { active == true }
    var safeToRestart: Bool {
        active == false && (strengthA ?? -1) == 0 && (strengthB ?? -1) == 0
            && (device?.strengthA ?? -1) == 0 && (device?.strengthB ?? -1) == 0
    }
}

private struct StatusEnvelope: Decodable {
    let ok: Bool
    let state: ConsoleSnapshot
}

@MainActor
final class ConsoleModel: ObservableObject {
    @Published private(set) var snapshot: ConsoleSnapshot?
    @Published private(set) var connected = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var log: [String] = []
    @Published var errorMessage = "" {
        didSet {
            let clean = AppDiagnostics.shared.redact(errorMessage)
            if clean != errorMessage { errorMessage = clean }
            if !clean.isEmpty && clean != oldValue {
                AppDiagnostics.shared.append(clean, category: "ERROR")
            }
        }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var deviceConnecting = false
    @Published var isQuitting = false
    private var refreshInFlight = false
    @Published private(set) var keyPresent = false
    @Published var enteredKey = ""
    @Published var apiPort: Int {
        didSet { UserDefaults.standard.set(apiPort, forKey: "DGLabLocalAPIPort") }
    }
    @Published var serviceLabel = "正在检查服务…"

    private var secret = ""
    private let session: URLSession
    let embeddedEngine = EmbeddedEngine()
    @Published var telegramEnabled = false {
        didSet { UserDefaults.standard.set(telegramEnabled, forKey: "DGDesktopTelegramEnabled") }
    }
    @Published var selectedDeviceMode = "mock" {
        didSet { UserDefaults.standard.set(selectedDeviceMode, forKey: "DGDesktopDeviceMode") }
    }
    @Published var ownerUserID = "" {
        didSet { UserDefaults.standard.set(ownerUserID, forKey: "DGDesktopOwnerID") }
    }
    @Published var allowedChatID = "" {
        didSet { UserDefaults.standard.set(allowedChatID, forKey: "DGDesktopChatID") }
    }
    @Published var bridgeHost = "127.0.0.1" {
        didSet { UserDefaults.standard.set(bridgeHost, forKey: "DGDesktopBridgeHost") }
    }
    @Published var enteredBotToken = ""
    @Published private(set) var botTokenPresent = false

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: "DGLabLocalAPIPort")
        apiPort = savedPort >= 1 && savedPort <= 65535 ? savedPort : 8789
        let config = URLSessionConfiguration.ephemeral
        // BLE scanning can legitimately take 15 seconds. Time out each request
        // explicitly below, not globally at seven seconds.
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 50
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        telegramEnabled = UserDefaults.standard.bool(forKey: "DGDesktopTelegramEnabled")
        selectedDeviceMode = UserDefaults.standard.string(forKey: "DGDesktopDeviceMode") ?? "mock"
        ownerUserID = UserDefaults.standard.string(forKey: "DGDesktopOwnerID") ?? ""
        allowedChatID = UserDefaults.standard.string(forKey: "DGDesktopChatID") ?? ""
        bridgeHost = UserDefaults.standard.string(forKey: "DGDesktopBridgeHost") ?? "127.0.0.1"
    }

    func prepare() {
        if secret.isEmpty {
            do {
                // Private App Support file; never touch Keychain on startup.
                secret = try AppPrivateStorage.createAPITokenIfMissing()
                keyPresent = !secret.isEmpty
            } catch {
                errorMessage = "无法在 App 私有目录保存 API 密钥：\(error.localizedDescription)"
            }
        }
        botTokenPresent = telegramSecret() != nil
        AppDiagnostics.shared.append("App launched; embedded engine starts only on explicit request", category: "APP")
        Task { await refresh() }
        Task { await refreshServiceStatus() }
    }

    func saveKey() {
        // Never change the key while the embedded engine expects the old
        // Bearer token, or safe stop/disconnect would become impossible.
        guard !embeddedEngine.running else {
            errorMessage = "请先安全停止内置引擎，再修改 API 密钥。"
            return
        }
        let cleaned = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.utf8.count >= 32 else { errorMessage = "桥接密钥至少需要 32 字节"; return }
        do {
            try AppPrivateStorage.saveAPI(cleaned)
            secret = cleaned
            keyPresent = true
            enteredKey = ""
            note("API 密钥已保存到 App 私有目录（不会访问钥匙串）")
            Task { await refresh() }
        } catch {
            errorMessage = "本地保存失败：\(error.localizedDescription)"
        }
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil,
                         confirmation: String? = nil) async throws -> Data {
        guard !secret.isEmpty else { throw NSError(domain: "DG-LAB", code: 401,
            userInfo: [NSLocalizedDescriptionKey: "请在 API / 服务页配置桥接密钥"] ) }
        guard let url = URL(string: "http://127.0.0.1:\(apiPort)\(path)") else {
            throw NSError(domain: "DG-LAB", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效 API 地址"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // Seconds, with polling kept short and hardware connection allowed to
        // complete its own 15-second discovery timeout before UI declares failure.
        req.timeoutInterval = method == "GET" ? 2.5 : (body?["command"] as? String == "device.connect" ? 40 : 22)
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let confirmation { req.setValue(confirmation, forHTTPHeaderField: "X-DGLab-Confirm") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if !(200...299).contains(http.statusCode) {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = payload?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "DG-LAB", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }

    func fetchSnapshot() async throws -> ConsoleSnapshot {
        let bytes = try await request(path: "/v1/status")
        return try JSONDecoder().decode(StatusEnvelope.self, from: bytes).state
    }
    func refresh() async {
        guard !refreshInFlight && !isQuitting else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        do {
            let current = try await fetchSnapshot()
            snapshot = current
            connected = true
            if errorMessage.hasPrefix("API 连接失败") ||
                (errorMessage == "设备未连接" && current.device?.connected == true) {
                errorMessage = ""
            }
        } catch {
            connected = false
            snapshot = nil // Unknown is never treated as zero output.
            if embeddedEngine.running && !errorMessage.hasPrefix("设备未连接") {
                errorMessage = "API 连接失败：\(error.localizedDescription)"
            }
        }
    }

    /// Synchronous from the caller's perspective. Engine shutdown must NEVER
    /// send a fire-and-forget stop and immediately SIGTERM the device owner.
    func disconnectForShutdown() async throws {
        let envelope = try await request(path: "/v1/command", method: "POST",
            body: ["command": "session.disconnect", "payload": [:]])
        guard let parsed = (try? JSONSerialization.jsonObject(with: envelope)) as? [String: Any],
              parsed["ok"] as? Bool == true else {
            throw NSError(domain: "DG-LAB", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "无法确认设备停止回执"])
        }
    }
    func command(_ name: String, payload: [String: Any] = [:], confirmation: String? = nil) {
        // Avoid duplicate asynchronous BLE connection attempts; one unresolved
        // scan can otherwise overlap the next and race a safe disconnection.
        if name == "device.connect" && deviceConnecting { return }
        Task {
            isWorking = true
            if name == "device.connect" { deviceConnecting = true }
            defer {
                isWorking = false
                if name == "device.connect" { deviceConnecting = false }
            }
            do {
                let data = try await request(path: "/v1/command", method: "POST",
                                             body: ["command": name, "payload": payload], confirmation: confirmation)
                let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let state = response?["state"] as? [String: Any]
                note(state?["message"] as? String ?? "已执行 \(name)")
                if name == "device.connect" { errorMessage = "" }
                await refresh()
            } catch {
                if name == "device.connect" {
                    errorMessage = "设备未连接"
                    note("设备连接失败：\(error.localizedDescription)")
                } else {
                    errorMessage = "操作 \(name) 失败：\(error.localizedDescription)"
                    note("请求未成功：\(name)")
                }
                await refresh()
            }
        }
    }
    func emergencyStop() { command("session.stop") }
    private func note(_ message: String, category: String = "APP") {
        let safe = AppDiagnostics.shared.redact(message)
        // On-screen history remains compact; persistent diagnostic logs keep
        // much more of each (redacted) engine error/stack trace.
        let summary = String(safe.prefix(250))
        lastMessage = summary
        log.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(summary)", at: 0)
        if log.count > 80 { log.removeLast(log.count - 80) }
        AppDiagnostics.shared.append(safe, category: category)
    }

    func bridgeSecret() -> String { secret }
    func telegramSecret() -> String? { AppPrivateStorage.telegramToken() }
    func saveBotToken() {
        let value = enteredBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^\d{6,15}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil else {
            errorMessage = "Telegram Bot Token 格式错误"; return
        }
        do {
            try AppPrivateStorage.saveTelegram(value)
            enteredBotToken = ""
            botTokenPresent = true
            note("Telegram 凭证已保存到 App 私有目录")
        } catch {
            errorMessage = "Telegram 凭证保存失败：\(error.localizedDescription)"
        }
    }

    func exportDiagnosticLogs() {
        do {
            if let file = try AppDiagnostics.shared.exportToUserChosenFile() {
                note("诊断日志已导出：\(file.lastPathComponent)")
            }
        } catch {
            errorMessage = "日志导出失败：\(error.localizedDescription)"
        }
    }
    func importLegacyConfiguration() {
        // Only extract non-secret configuration keys, never copy a private plist
        // or store the historic Bot Token inside the app's public package.
        let file = NSHomeDirectory() + "/Library/LaunchAgents/com.dglab.telegram-bot.plist"
        if let data = FileManager.default.contents(atPath: file),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let env = dict["EnvironmentVariables"] as? [String: String] {
            if ownerUserID.isEmpty { ownerUserID = env["TG_OWNER_USER_ID"] ?? "" }
            if allowedChatID.isEmpty { allowedChatID = env["TG_ALLOWED_CHAT_ID"] ?? "" }
            // NEVER import the previous deviceMode automatically: first-run mock.
        }
        botTokenPresent = telegramSecret() != nil
        note("只读取旧设置中的非敏感字段；不会触碰旧钥匙串。API/Telegram 密钥需要手动重新输入。")
    }
    func appendEngineMessage(_ message: String) {
        for line in message.split(separator: "\n").prefix(8) {
            note(String(line), category: "ENGINE")
        }
    }
    func refreshServiceStatus() async {
        serviceLabel = embeddedEngine.running ? "内置引擎：运行中" : "内置引擎：已停止"
    }
    func runSelfTest() {
        Task {
            guard !embeddedEngine.running else {
                errorMessage = "请先停止内置引擎，再进行独立 Mock 自检"; return
            }
            await embeddedEngine.start(model: self, diagnosticMock: true)
            if connected, let fresh = try? await fetchSnapshot(),
               fresh.deviceMode == "mock", fresh.safeToRestart {
                appendEngineMessage("自检成功：内置 Node/REST/OBS/模拟设备均可运行，没有实体输出")
                await embeddedEngine.stop(model: self)
            } else {
                errorMessage = "Mock 自检失败：请查看日志和本地 API 状态"
            }
        }
    }

    func manageService(_ action: String) {
        Task {
            isWorking = true
            defer { isWorking = false }
            switch action {
            case "start": await embeddedEngine.start(model: self)
            case "restart":
                if await embeddedEngine.stop(model: self) {
                    await embeddedEngine.start(model: self)
                }
            case "stop": _ = await embeddedEngine.stop(model: self)
            default: break
            }
        }
    }
    var obsURL: URL? { URL(string: snapshot?.obsURL ?? "http://127.0.0.1:8787/obs") }
    var localAPIBase: String { "http://127.0.0.1:\(apiPort)" }
    var generatedCurlExample: String {
        "curl -H 'Authorization: Bearer <YOUR_LOCAL_BRIDGE_TOKEN>' \(localAPIBase)/v1/status"
    }
}
