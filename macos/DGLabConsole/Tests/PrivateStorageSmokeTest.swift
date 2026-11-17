import AppKit
import Darwin
import Foundation

@main
struct AppStorageSmokeTest {
    @MainActor static func main() throws {
        let root = try AppPrivateStorage.root()
        let token = try AppPrivateStorage.createAPITokenIfMissing()
        precondition(token.utf8.count >= 32)
        precondition(AppPrivateStorage.apiToken() == token)
        let sampleTG = "123456789:" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789"
        try AppPrivateStorage.saveTelegram(sampleTG)
        precondition(AppPrivateStorage.telegramToken() == sampleTG)
        precondition(AppPrivateStorage.apiToken() == token)
        let file = root.appendingPathComponent("credentials.json")
        let attr = try FileManager.default.attributesOfItem(atPath: file.path)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileMode = attr[.posixPermissions] as? NSNumber
        let dirMode = dirAttrs[.posixPermissions] as? NSNumber
        precondition(fileMode?.intValue == 0o600)
        precondition(dirMode?.intValue == 0o700)
        let logger = AppDiagnostics.shared
        logger.append("Bearer \(token); TG=\(sampleTG); original-body=none", category: "TEST")
        logger.append("simulated connection failure 401", category: "ENGINE")
        let report = try logger.buildReport()
        precondition(report.contains("simulated connection failure"))
        precondition(report.contains("[REDACTED]"))
        precondition(!report.contains(token))
        precondition(!report.contains(sampleTG))
        let logFile = root.appendingPathComponent("Logs/dg-lab.log")
        let logAttrs = try FileManager.default.attributesOfItem(atPath: logFile.path)
        precondition((logAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("APP_PRIVATE_FILE_TEST_PASS mode=0600 directory=0700")
        print("CREDENTIAL_PERSISTENCE_PASS")
        print("REDACTED_LOG_REPORT_PASS bytes=\(report.utf8.count)")
    }
}
