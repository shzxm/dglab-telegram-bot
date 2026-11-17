import SwiftUI

@main
struct DGLabConsoleApp: App {
    @StateObject private var model = ConsoleModel()

    var body: some Scene {
        WindowGroup("DG-LAB 控制台") {
            ConsoleWindow()
                .environmentObject(model)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    model.prepare()
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
