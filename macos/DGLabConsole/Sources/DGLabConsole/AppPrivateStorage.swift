import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Private, non-sandboxed user-local App Support data. No macOS Keychain or TCC access.
/// File permissions are a local-user privacy boundary, NOT hardware encryption.
enum AppPrivateStorage {
    private struct Credentials: Codable {
        var version = 1
        var apiToken: String = ""
        var telegramToken: String? = nil
    }

    static func root() throws -> URL {
        #if DEBUG
        // Test-only sandbox: release builds cannot redirect private credentials.
        let testRoot = ProcessInfo.processInfo.environment["DGLAB_TEST_STORAGE_ROOT"]
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        let root = testRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("DG-LAB Console", isDirectory: true)
        #else
        let root = base.appendingPathComponent("DG-LAB Console", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private static func credentialFile() throws -> URL {
        try root().appendingPathComponent("credentials.json")
    }

    static func apiToken() -> String? {
        readCredentials()?.apiToken.nonEmpty
    }

    static func telegramToken() -> String? {
        readCredentials()?.telegramToken?.nonEmpty
    }

    static func saveAPI(_ value: String) throws {
        var data = readCredentials() ?? Credentials()
        data.apiToken = value
        try save(data)
    }

    static func saveTelegram(_ value: String) throws {
        var data = readCredentials() ?? Credentials()
        data.telegramToken = value
        try save(data)
    }

    private static func readCredentials() -> Credentials? {
        guard let file = try? credentialFile() else { return nil }
        // Never follow a symbolic link masquerading as a credential file.
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        guard let raw = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: raw)
    }

    static func createAPITokenIfMissing() throws -> String {
        if let current = apiToken(), current.utf8.count >= 32 { return current }
        if let file = try? credentialFile(), FileManager.default.fileExists(atPath: file.path) {
            throw NSError(domain: "DG-LAB.PrivateStorage", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "现有凭证无效，未覆盖原文件。请检查本地配置。"])
        }
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        try saveAPI(token)
        return token
    }

    private static func save(_ record: Credentials) throws {
        let file = try credentialFile()
        // Preserve an unreadable/corrupt prior file instead of silently
        // overwriting a user's existing credentials.
        if FileManager.default.fileExists(atPath: file.path) && readCredentials() == nil {
            throw NSError(domain: "DG-LAB.PrivateStorage", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "私有凭证文件无法读取或已损坏，未覆盖原文件"])
        }
        let bytes = try JSONEncoder().encode(record)
        try secureAtomicWrite(bytes, to: file)
    }

    /// Creates a temporary regular file as 0600, writes and fsyncs before a
    /// same-directory atomic rename. No intermediate world-readable file.
    static func secureAtomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let temp = parent.appendingPathComponent(".temp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); _ = unlink(temp.path) }
        try data.withUnsafeBytes { raw in
            guard let start = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, start.advanced(by: written), raw.count - written)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += n
            }
        }
        guard fsync(fd) == 0, rename(temp.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Persistent, bounded, redacted support logs. Does NOT include raw API tokens,
/// Telegram credentials, request Authorization headers or clipboard values.
@MainActor
final class AppDiagnostics {
    static let shared = AppDiagnostics()
    private let maxFileSize = 2 * 1024 * 1024
    private let keepFiles = 3
    private init() {}

    private func directory() throws -> URL {
        var dir = try AppPrivateStorage.root().appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try? dir.setResourceValues(resource)
        return dir
    }

    private func active() throws -> URL { try directory().appendingPathComponent("dg-lab.log") }

    func redact(_ input: String) -> String {
        var result = input
        for known in [AppPrivateStorage.apiToken(), AppPrivateStorage.telegramToken()].compactMap({ $0 }) where !known.isEmpty {
            result = result.replacingOccurrences(of: known, with: "[REDACTED]")
        }
        let patterns: [String] = [
            #"(?i)\bBearer\s+[^\s,;\"']+"#,
            #"\b[0-9]{6,15}:[A-Za-z0-9_-]{20,}\b"#,
            #"(?i)(?:api[_-]?key|bot[_-]?token|bridge[_-]?token|ios_bridge_token|authorization|secret|password)\s*[=:]\s*[^\s,;\"']+"#,
            #"(?i)(?:api[_-]?key|bot[_-]?token|bridge[_-]?token|ios_bridge_token|secret|password)\s*[=:]\s*[\"'][^\"']+[\"']"#,
            #"\b[A-Fa-f0-9]{48,128}\b"#,
        ]
        for expression in patterns {
            result = result.replacingOccurrences(of: expression, with: "[REDACTED]", options: .regularExpression)
        }
        return result
    }

    func append(_ value: String, category: String) {
        do {
            let file = try active()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let cleaned = redact(value).replacingOccurrences(of: "\u{0000}", with: "")
            let lines = cleaned.components(separatedBy: .newlines).filter { !$0.isEmpty }.prefix(24)
            let payload = lines.map { "[\(timestamp)] [\(category)] \($0.prefix(1400))\n" }.joined()
            guard !payload.isEmpty else { return }
            if (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0) ?? 0 > maxFileSize {
                let root = try directory()
                let oldest = root.appendingPathComponent("dg-lab.\(keepFiles).log")
                try? FileManager.default.removeItem(at: oldest)
                for index in stride(from: keepFiles, through: 1, by: -1) {
                    let old = root.appendingPathComponent(index == 1 ? "dg-lab.log" : "dg-lab.\(index - 1).log")
                    let next = root.appendingPathComponent("dg-lab.\(index).log")
                    if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.moveItem(at: old, to: next) }
                }
            }
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { return }
            defer { close(fd) }
            let bytes = Array(payload.utf8)
            bytes.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, ptr.advanced(by: offset), raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { break }
                    offset += written
                }
            }
        } catch { /* Logging must never prevent safe device shutdown. */ }
    }

    func buildReport() throws -> String {
        var report = "DG-LAB macOS Console — Diagnostic Log Export\n"
        report += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        report += "App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")\n"
        report += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        report += "Raw credentials, device serials, clipboard and Authorization headers are not exported.\n\n"
        let root = try directory()
        for item in ["dg-lab.3.log", "dg-lab.2.log", "dg-lab.1.log", "dg-lab.log"] {
            let url = root.appendingPathComponent(item)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            report += "===== \(item) =====\n\(redact(raw))\n"
        }
        return redact(report)
    }

    func exportToUserChosenFile() throws -> URL? {
        let picker = NSSavePanel()
        picker.title = "导出 DG-LAB 诊断日志"
        picker.nameFieldStringValue = "DG-LAB-Diagnostics-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).txt"
        picker.allowedContentTypes = [.plainText]
        picker.message = "只导出脱敏诊断日志，不包含 API 密钥或 Telegram Token。请在分享前再次检查内容。"
        guard picker.runModal() == .OK, let destination = picker.url else { return nil }
        // The user-selected export location is not required to be private.
        // Content is redacted once more as a defense against token changes.
        try Data(redact(try buildReport()).utf8).write(to: destination, options: .atomic)
        return destination
    }
}
