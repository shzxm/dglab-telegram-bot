import SwiftUI
import DGLabCore

@main
struct DGLabControlApp: App {
    @StateObject private var controller = DGLabController()
    @Environment(\.scenePhase) private var phase
    @State private var showPartnerHandoffNotice = false
    var body: some Scene {
        WindowGroup {
            MainNavigation()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
                .tint(.cyan)
                .onOpenURL { url in
                    guard url.scheme == "dglabcontrol", url.host == "open" else { return }
                    // Never arm, connect BLE, alter A/B strength or start a
                    // session in response to an external deep link.
                    showPartnerHandoffNotice = true
                }
                .alert("已打开 DG-LAB 控制台", isPresented: $showPartnerHandoffNotice) {
                    Button("了解", role: .cancel) {}
                } message: {
                    Text("跨应用切换不会自动连接设备或启动电刺激。请在本应用内主动授权。")
                }
                .onChange(of: phase) { _, newPhase in
                    if newPhase != .active && controller.sessionStarted {
                        // A phone cannot guarantee 100ms BLE writes while suspended.
                        controller.stopLocal(reason: "App 进入后台，已按安全策略停止输出")
                    }
                }
        }
    }
}
