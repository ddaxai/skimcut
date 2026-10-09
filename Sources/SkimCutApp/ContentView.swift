import SkimCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            if let url = model.videoURL {
                Text(url.lastPathComponent)
                    .font(.title2)
                Text("已收到文件。播放器和时间轴将在 M1 中实现。")
                    .foregroundStyle(.secondary)
            } else {
                Text("把视频拖到这里")
                    .font(.title2)
                Text("也可以用菜单“文件 > 打开…”（⌘O），或者把视频拖到 Dock 图标上")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Divider()
            ToolStatusView(model: model)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .task {
            await model.checkTools()
        }
    }
}

/// 外部工具检测结果：从 Finder 启动时也必须能找到 Homebrew 安装的工具。
struct ToolStatusView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("外部工具")
                    .font(.headline)
                Spacer()
                if model.isCheckingTools {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("重新检测") {
                    Task { await model.checkTools() }
                }
                .disabled(model.isCheckingTools)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(model.tools) { status in
                    GridRow {
                        Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(status.isAvailable ? Color.green : Color.red)
                        Text(status.tool.rawValue)
                            .monospaced()
                        Text(status.version ?? (status.isAvailable ? "?" : "未找到"))
                        Text(status.path ?? "安装：\(status.tool.installHint)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
