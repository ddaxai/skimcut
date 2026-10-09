import AppKit
import Observation
import SkimCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// 当前打开的视频（M0 只显示文件名，播放器在 M1 实现）。
    private(set) var videoURL: URL?
    private(set) var tools: [ToolStatus] = []
    private(set) var isCheckingTools = false

    func open(_ url: URL) {
        videoURL = url
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    /// 检查外部工具（只在启动时和用户点击“重新检测”时运行一次）。
    func checkTools() async {
        guard !isCheckingTools else { return }
        isCheckingTools = true
        ToolLocator.shared.resetCache()
        tools = await ToolInventory.check()
        isCheckingTools = false
    }
}
