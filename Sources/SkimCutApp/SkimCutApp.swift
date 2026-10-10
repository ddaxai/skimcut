import AppKit
import SkimCore
import SwiftUI

@main
struct SkimCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        Window("SkimCut", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("导出选区") {
                    if let player = model.player, let cut = model.cut {
                        model.exportCuts(source: cut.source, ranges: [player.selectedRange], mode: cut.mode)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.player == nil)
                Button("关闭视频") { model.closeVideo() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.player == nil)
            }
            // 单键快捷键（空格、J/K/L、方向键）由播放画面和时间轴直接处理，
            // 菜单里只列出来，不注册成菜单快捷键，以免以后在文本框里打字时被拦截。
            CommandMenu("播放") {
                Button("播放 / 暂停　空格") { model.player?.perform(.togglePlay) }
                Button("倒放 / 加速　J") { model.player?.perform(.shuttleReverse) }
                Button("暂停　K") { model.player?.perform(.shuttleStop) }
                Button("播放 / 加速　L") { model.player?.perform(.shuttleForward) }
                Divider()
                Button("上一帧　←") { model.player?.perform(.stepBackward) }
                Button("下一帧　→") { model.player?.perform(.stepForward) }
                Button("后退几秒　Shift ←") { model.player?.perform(.jumpBackward) }
                Button("前进几秒　Shift →") { model.player?.perform(.jumpForward) }
                Divider()
                Button("起点设在这里　I") { model.player?.perform(.markIn) }
                Button("终点设在这里　O") { model.player?.perform(.markOut) }
                Button("清除选区") { model.player?.resetSelection() }
            }
            CommandGroup(after: .toolbar) {
                Button("放大时间轴") { model.player?.perform(.zoomIn) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model.player == nil)
                Button("缩小时间轴") { model.player?.perform(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model.player == nil)
                Button("整段显示时间轴") { model.player?.zoomToFit() }
                    .disabled(model.player == nil)
                Divider()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 清理上次异常退出留下的预览临时文件。
        Task.detached(priority: .background) {
            PreviewFileStore.purgeStale()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 视频拖到 Dock 图标上、或者在 Finder 里用“打开方式”选择 SkimCut。
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            AppModel.shared.open(url)
        }
    }

    /// 退出时结束所有子进程（并删除没完成的输出文件），释放播放器，删除预览临时文件。
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRegistry.shared.terminateAll()
        AppModel.shared.prepareForTermination()
    }
}
