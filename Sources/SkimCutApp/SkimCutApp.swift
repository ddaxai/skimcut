import AppKit
import SkimCore
import SwiftUI

@main
struct SkimCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("SkimCut", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 视频拖到 Dock 图标上、或者在 Finder 里用“打开方式”选择 SkimCut。
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            AppModel.shared.open(url)
        }
    }

    /// 退出时结束所有子进程，并删除没完成的输出文件。
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRegistry.shared.terminateAll()
    }
}
