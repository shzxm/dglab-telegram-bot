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
                    }
                    // This refresh only queries state; it never triggers stimulation.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if Task.isCancelled { break }
                        await model.refresh()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.embeddedEngine.running else { return .terminateNow }
        guard model.snapshot?.safeToRestart == true else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "内置 DG-LAB 引擎仍可能在输出"
            alert.informativeText = "请先在 App 内停止设备会话，并确认 A/B 都归零，然后安全停止内置引擎，再退出。"
            alert.addButton(withTitle: "返回控制台")
            alert.runModal()
            return .terminateCancel
        }
        return model.embeddedEngine.mayQuit(model: model) ? .terminateNow : .terminateCancel
    }
}
