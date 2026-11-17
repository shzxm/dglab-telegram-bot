import SwiftUI
import Foundation
import Combine
import Security
import DGLabCore

/// Independent bridge credential in iPhone Keychain. Never stores the Telegram Bot token.
enum RelayCredentials {
    private static let service = "com.shzxm.DGLabControl.relay"
    static func save(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        let item = query.merging([kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new }
        SecItemAdd(item as CFDictionary, nil)
    }
    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct RelayStatus: Equatable {
    var active = false
    var strengthA = 0
    var strengthB = 0
    var mode = "collaboration"
    var participants = 0
    var waveformA = "波浪"
    var waveformB = "波浪"
    var inviteCode = ""
    var groupId: Int64? = nil
    var operators: [String] = []
    var eventPool = "全部"
    var expiresAt: TimeInterval = 0
    var votes: [String: Int] = [:]
    var rampA = false
    var rampB = false
    var rampDoneA = 0
    var rampDoneB = 0
    var rampRateA = 3
    var rampRateB = 3
    var rampMaxA = 10
    var rampMaxB = 10
}

@MainActor
final class TelegramRelay: ObservableObject {
    // Per-user network address: never bake a developer's LAN IP into public code.
    @Published var endpoint = UserDefaults.standard.string(forKey: "DGLabRelayEndpoint") ?? ""
    @Published private(set) var connected = false
    @Published private(set) var connectionLabel = "未连接 Telegram 桥接"
    @Published private(set) var relayStatus = RelayStatus()
    @Published private(set) var assignedRole: ControlRole = .remote
    @Published var lastMessage = ""

    var onHostInstruction: ((String, [String: Any]) async throws -> [String: Any])?
    var onHostDisconnected: (() -> Void)?
    var onRemoteAudioMetric: ((Double) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var connectingRole: ControlRole = .remote
    private var intentionalDisconnect = false

    func connect(role: ControlRole, token: String) throws {
        guard role != .standalone else { throw DGControlError.rejected }
        guard let url = URL(string: endpoint), ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !token.isEmpty else { throw DGControlError.relayDisconnected }
        // Plain WS allowed only on local / private networks. Internet connections must use TLS.
        if url.scheme?.lowercased() == "ws" {
            let isLocal = host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.16.") || host.hasPrefix("172.17.")
            guard isLocal else { throw DGControlError.rejected }
        }
        UserDefaults.standard.set(endpoint, forKey: "DGLabRelayEndpoint")
        disconnect()
        connectingRole = role
        intentionalDisconnect = false
        RelayCredentials.save(token)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession(configuration: .default).webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        connectionLabel = "正在连接…"
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let current = self.socket, current === socket else { return }
                current.sendPing { error in
                    if error != nil { Task { @MainActor in self.markDisconnected() } }
                }
            }
        }
        Task { try? await send(["type": "hello", "role": role == .host ? "host" : "remote", "platform": "ios"]) }
    }
    private func send(_ payload: [String: Any]) async throws {
        guard let socket else { throw DGControlError.relayDisconnected }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let message = String(data: data, encoding: .utf8) else { throw DGControlError.rejected }
        try await socket.send(.string(message))
    }
    func command(_ command: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        guard connected else { throw DGControlError.relayDisconnected }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await send(["type": "command", "id": id, "command": command, "payload": payload]) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                pending.removeValue(forKey: id)?.resume(throwing: DGControlError.requestTimedOut)
            }
        }
    }
    private func receiveLoop(_ connection: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await connection.receive()
                let raw: String
                switch message {
                case .string(let text): raw = text
                case .data(let data): raw = String(data: data, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                guard let bytes = raw.data(using: .utf8),
                      let item = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let type = item["type"] as? String else { continue }
                switch type {
                case "ready":
                    connected = true; assignedRole = connectingRole
                    connectionLabel = connectingRole == .host ? "已连接 · iPhone 蓝牙主机" : "已连接 · Telegram 控制"
                case "snapshot":
                    readSnapshot(item["state"] as? [String: Any] ?? item)
                case "ack":
                    if let id = item["id"] as? String, let completion = pending.removeValue(forKey: id) {
                        if item["ok"] as? Bool == true { completion.resume(returning: item["state"] as? [String: Any] ?? [:]) }
                        else { completion.resume(throwing: NSError(domain: "DGLabRelay", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: item["error"] as? String ?? "Bot 拒绝了操作"])) }
                    }
                case "command":
                    if connectingRole == .host { await executeHostInstruction(item) }
                case "audio.metric":
                    if let level = item["rms"] as? Double { onRemoteAudioMetric?(level) }
                case "event": lastMessage = item["message"] as? String ?? "收到事件"
                default: break
                }
            } catch {
                if !intentionalDisconnect { lastMessage = "连接中断：\(error.localizedDescription)" }
                markDisconnected(); return
            }
        }
    }
    private func executeHostInstruction(_ item: [String: Any]) async {
        guard let id = item["id"] as? String, let command = item["command"] as? String else { return }
        do {
            guard let onHostInstruction else { throw DGControlError.rejected }
            let result = try await onHostInstruction(command, item["payload"] as? [String: Any] ?? [:])
            try await send(["type": "ack", "id": id, "ok": true, "state": result])
        } catch {
            try? await send(["type": "ack", "id": id, "ok": false, "error": error.localizedDescription])
        }
    }
    private func readSnapshot(_ value: [String: Any]) {
        relayStatus.active = value["active"] as? Bool ?? false
        relayStatus.strengthA = value["strengthA"] as? Int ?? 0
        relayStatus.strengthB = value["strengthB"] as? Int ?? 0
        relayStatus.mode = value["mode"] as? String ?? "collaboration"
        relayStatus.participants = value["participants"] as? Int ?? 0
        relayStatus.waveformA = value["waveformA"] as? String ?? "波浪"
        relayStatus.waveformB = value["waveformB"] as? String ?? "波浪"
        relayStatus.inviteCode = value["inviteCode"] as? String ?? ""
        relayStatus.groupId = value["groupId"] as? Int64
        relayStatus.operators = value["operators"] as? [String] ?? []
        relayStatus.eventPool = value["eventPool"] as? String ?? "全部"
        relayStatus.expiresAt = value["expiresAt"] as? TimeInterval ?? 0
        relayStatus.votes = value["votes"] as? [String: Int] ?? [:]
        relayStatus.rampA = value["rampA"] as? Bool ?? false
        relayStatus.rampB = value["rampB"] as? Bool ?? false
        relayStatus.rampDoneA = value["rampDoneA"] as? Int ?? 0
        relayStatus.rampDoneB = value["rampDoneB"] as? Int ?? 0
        relayStatus.rampRateA = value["rampRateA"] as? Int ?? 3
        relayStatus.rampRateB = value["rampRateB"] as? Int ?? 3
        relayStatus.rampMaxA = value["rampMaxA"] as? Int ?? 10
        relayStatus.rampMaxB = value["rampMaxB"] as? Int ?? 10
    }
    func disconnect() {
        intentionalDisconnect = true
        socket?.cancel(with: .normalClosure, reason: nil)
        markDisconnected()
    }
    private func markDisconnected() {
        let wasHost = assignedRole == .host && connected
        connected = false
        socket = nil
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        for (_, completion) in pending { completion.resume(throwing: DGControlError.relayDisconnected) }
        pending.removeAll()
        connectionLabel = "桥接未连接"
        if wasHost { onHostDisconnected?() }
    }
}
