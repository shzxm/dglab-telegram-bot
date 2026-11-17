import AppKit
import Combine
import Foundation
import Security

// The native UI is only a client. Telegram polling and all physical output
// remain in the existing single Node.js backend.
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

private enum ConsoleKeychain {
    static let appService = "com.shzxm.dglab-macos-console.token"
    static let existingBridgeService = "dglab-ios-bridge"

    static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ secret: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: appService,
                                    kSecAttrAccount as String: "local-admin"]
        SecItemDelete(query as CFDictionary)
        var payload = query
        payload[kSecValueData as String] = Data(secret.utf8)
        payload[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(payload as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class ConsoleModel: ObservableObject {
    @Published private(set) var snapshot: ConsoleSnapshot?
    @Published private(set) var connected = false
    @Published private(set) var lastMessage = ""
    @Published private(set) var log: [String] = []
    @Published var errorMessage = ""
    @Published private(set) var isWorking = false
    @Published private(set) var keyPresent = false
    @Published var enteredKey = ""
    @Published var apiPort: Int {
        didSet { UserDefaults.standard.set(apiPort, forKey: "DGLabLocalAPIPort") }
    }
    @Published var serviceLabel = "正在检查服务…"

    private var secret = ""
    private let session: URLSession
    private let service = "com.dglab.telegram-bot"

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: "DGLabLocalAPIPort")
        apiPort = savedPort >= 1 && savedPort <= 65535 ? savedPort : 8789
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func prepare() {
        if secret.isEmpty {
            secret = ConsoleKeychain.load(service: ConsoleKeychain.appService)
                ?? ConsoleKeychain.load(service: ConsoleKeychain.existingBridgeService) ?? ""
            keyPresent = !secret.isEmpty
        }
        Task { await refresh() }
        Task { await refreshServiceStatus() }
    }

    func saveKey() {
        let cleaned = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 32 else { errorMessage = "桥接密钥至少需要 32 个字符"; return }
        guard ConsoleKeychain.save(cleaned) else { errorMessage = "无法保存到 macOS 钥匙串"; return }
        secret = cleaned
        keyPresent = true
        enteredKey = ""
        note("密钥已保存到本机钥匙串")
        Task { await refresh() }
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
        do {
            let current = try await fetchSnapshot()
            snapshot = current
            connected = true
            if errorMessage.hasPrefix("API ") { errorMessage = "" }
        } catch {
            connected = false
            snapshot = nil // Never present stale zero strength as permission to restart!
            errorMessage = "API 连接失败：\(error.localizedDescription)"
        }
    }
    func command(_ name: String, payload: [String: Any] = [:], confirmation: String? = nil) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let data = try await request(path: "/v1/command", method: "POST",
                                             body: ["command": name, "payload": payload], confirmation: confirmation)
                let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let state = response?["state"] as? [String: Any]
                note(state?["message"] as? String ?? "已执行 \(name)")
                await refresh()
            } catch {
                errorMessage = "操作 \(name) 被拒绝：\(error.localizedDescription)"
                note("请求未成功：\(name)")
                await refresh()
            }
        }
    }
    func emergencyStop() { command("session.stop") }
    private func note(_ message: String) {
        lastMessage = message
        log.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)", at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    private func launchctl(_ args: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // launchctl output is small and the command is bounded to fixed arguments.
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "launchctl", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "操作失败" : output])
            }
            return output
        }.value
    }
    func refreshServiceStatus() async {
        do {
            let value = try await launchctl(["print", "gui/\(getuid())/\(service)"])
            serviceLabel = value.contains("state = running") ? "后台 Bot：运行中" : "后台 Bot：已加载但未运行"
        } catch { serviceLabel = "后台 Bot：未注册或无法读取" }
    }
    func manageService(_ action: String) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                if action == "restart" || action == "stop" {
                    let fresh = try await fetchSnapshot()
                    guard fresh.safeToRestart else {
                        throw NSError(domain: "DG-LAB", code: 423,
                                    userInfo: [NSLocalizedDescriptionKey: "存在活动输出或状态不确定，拒绝重启/停止后台；请先停止会话并归零"])
                    }
                }
                let domain = "gui/\(getuid())/\(service)"
                switch action {
                case "start":
                    // Never use -k when the service could already be controlling a device.
                    let details = try? await launchctl(["print", domain])
                    if details?.contains("state = running") == true {
                        note("Bot 已运行，无需重新启动")
                    } else if details == nil {
                        let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(service).plist"
                        _ = try await launchctl(["bootstrap", "gui/\(getuid())", plist])
                        note("Bot 已加载")
                    } else {
                        _ = try await launchctl(["kickstart", domain])
                        note("Bot 已启动")
                    }
                case "restart":
                    _ = try await launchctl(["kickstart", "-k", domain]); note("Bot 已重新加载")
                case "stop":
                    _ = try await launchctl(["bootout", domain]); note("Bot 服务已停止")
                default: return
                }
                try? await Task.sleep(nanoseconds: 950_000_000)
                await refreshServiceStatus()
                await refresh()
            } catch { errorMessage = "服务操作失败：\(error.localizedDescription)" }
        }
    }

    var obsURL: URL? { URL(string: snapshot?.obsURL ?? "http://127.0.0.1:8787/obs") }
    var localAPIBase: String { "http://127.0.0.1:\(apiPort)" }
    var generatedCurlExample: String {
        "curl -H 'Authorization: Bearer <YOUR_LOCAL_BRIDGE_TOKEN>' \(localAPIBase)/v1/status"
    }
}
