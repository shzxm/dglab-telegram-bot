import SwiftUI

@main
struct DGLabConsoleApp: App {
    @StateObject private var model = ConsoleModel()
    @NSApplicationDelegateAdaptor(DGLabAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("DG-LAB 控制台") {
            ConsoleWindow()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    appDelegate.model = model
                    model.prepare()
                    if ProcessInfo.processInfo.arguments.contains("--dg-diagnostic-mock") {
                        // Safe, opt-in, one-shot end-to-end integration check.
                        // Never contacts Telegram and never opens physical BLE.
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        model.runSelfTest()
                    } else if ProcessInfo.processInfo.arguments.contains("--dg-diagnostic-persistent-mock") {
                        // Diagnostic mode always forces mock + offline, even if
                        // the saved user setting is BLE or Telegram enabled.
                        // Used to verify Quit stops an ACTIVE simulated session.
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        await model.embeddedEngine.start(model: model, diagnosticMock: true)
                    }
                    // This refresh only queries state; it never triggers stimulation.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { break }
                        await model.refresh()
                        if !model.embeddedEngine.running { await model.refreshServiceStatus() }
                    }
                }
        }
        .defaultSize(width: 1050, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("设备控制") {
                Button("立即停止会话并尝试归零") { model.emergencyStop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class DGLabAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ConsoleModel?

    /// Closing the final window behaves like Quit: no hidden stimulator process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // System-audio permission probe is a separate helper; close it even
        // when the main Node engine was never started.
        PermissionCenter.shared.stopAudioTest()
        guard let model, model.embeddedEngine.running else { return .terminateNow }
        guard !model.isQuitting else { return .terminateLater }
        model.isQuitting = true
        Task { @MainActor in
            let stopped = await model.embeddedEngine.stop(model: model)
            if !stopped {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "DG-LAB 引擎未能安全关闭"
                alert.informativeText = "已保留控制界面。请检查设备连接、硬件停止方式及错误信息，确认设备断开后重试退出。"
                alert.addButton(withTitle: "返回控制台")
                alert.runModal()
                model.isQuitting = false
            }
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}
