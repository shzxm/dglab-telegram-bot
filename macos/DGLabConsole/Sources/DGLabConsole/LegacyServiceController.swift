import Foundation
import Darwin

/// Explicit migration from the OLD separately installed user LaunchAgent to
/// the self-contained App. Never reads Keychain or tries to control hardware.
/// Observing a zero-output legacy dashboard is NOT a substitute for a physical
/// stop switch or confirmation that the real BLE peripheral is disconnected.
enum LegacyServiceController {
    static let label = "com.dglab.telegram-bot"

    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        child.arguments = arguments
        child.standardOutput = Pipe()
        child.standardError = Pipe()
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }

    static func isLoaded() -> Bool {
        (try? launchctl(["print", "gui/\(getuid())/\(label)"])) == 0
    }

    /// Verify the old controller is genuinely idle before asking launchd to
    /// terminate it. It will run its existing SIGTERM stop/disconnect hooks.
    private static func isLegacyDashboardIdle() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8787/state") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let active = value["active"] as? Bool
        let a = value["strengthA"] as? Int
        let b = value["strengthB"] as? Int
        return active == false && a == 0 && b == 0
    }

    static func stopIdleLegacyAgent() async throws {
        guard isLoaded() else { return }
        guard await isLegacyDashboardIdle() else {
            throw NSError(domain: "DG-LAB.Legacy", code: 423,
                userInfo: [NSLocalizedDescriptionKey: "旧控制器未确认会话停止且 A/B 均为零。请先在旧控制器停止输出并断开实体设备。"])
        }
        let status = try launchctl(["bootout", "gui/\(getuid())/\(label)"])
        guard status == 0 else {
            throw NSError(domain: "DG-LAB.Legacy", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "停止旧 LaunchAgent 失败（退出码 \(status)）"])
        }
        for _ in 0..<50 {
            if !isLoaded(), await portsFree() { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw NSError(domain: "DG-LAB.Legacy", code: 504,
            userInfo: [NSLocalizedDescriptionKey: "旧服务仍占用端口。已取消启动新引擎，避免控制冲突。"])
    }

    static func restoreLegacyAgent() async throws {
        guard !isLoaded(), await portsFree() else {
            throw NSError(domain: "DG-LAB.Legacy", code: 409,
                userInfo: [NSLocalizedDescriptionKey: "旧服务已运行或新控制引擎仍占用端口"])
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "DG-LAB.Legacy", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "旧版 LaunchAgent 配置文件不存在"])
        }
        let status = try launchctl(["bootstrap", "gui/\(getuid())", file.path])
        guard status == 0 else {
            throw NSError(domain: "DG-LAB.Legacy", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "恢复旧控制器失败（退出码 \(status)）"])
        }
    }

    static func portsFree() async -> Bool {
        for port in [8787, 8788, 8789] {
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 1
            if (try? await URLSession(configuration: .ephemeral).data(for: req)) != nil { return false }
        }
        return true
    }
}
