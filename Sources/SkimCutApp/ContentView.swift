import SkimCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if let player = model.player {
                PlayerScreen(player: player)
            } else {
                EmptyStateView(model: model)
            }
            LoadStateOverlay(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(model.player?.sourceURL.lastPathComponent ?? "SkimCut")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
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

// MARK: - 播放界面

struct PlayerScreen: View {
    let player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(controller: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TransportBar(player: player)
            TimelineStrip(controller: player)
                .frame(height: TimelineMetrics.totalHeight)
        }
        .background(Color.black)
    }
}

struct TransportBar: View {
    let player: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.perform(.togglePlay)
            } label: {
                Image(systemName: player.mode == .user ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("播放 / 暂停（空格）")

            Text(Timecode.format(player.playhead))
                .font(.system(.title3, design: .monospaced))
                .help("播放头位置")

            if let skimmer = player.skimmerTime {
                Text(Timecode.format(skimmer))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
                    .help("鼠标（skimmer）位置")
            }

            if player.mode == .user, player.rate != 1, player.rate != 0 {
                Text(rateText(player.rate))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if player.strategy != .native {
                Label(player.strategy == .remux ? "预览：转封装" : "预览：低分辨率代理", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("AVPlayer 不能直接播放原文件，这里播放的是临时预览文件。导出时永远使用原文件，关闭视频时临时文件会被删除。")
            }

            HStack(spacing: 4) {
                Button { player.zoom(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小时间轴（⌘-）")
                Button { player.zoomToFit() } label: { Image(systemName: "arrow.left.and.right") }
                    .help("整段显示")
                Button { player.zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大时间轴（⌘+）")
            }
            .buttonStyle(.borderless)
            .focusable(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func rateText(_ rate: Float) -> String {
        let magnitude = abs(rate)
        let number = magnitude == magnitude.rounded() ? String(Int(magnitude)) : String(magnitude)
        return (rate < 0 ? "◀︎ " : "▶︎ ") + number + "×"
    }
}

// MARK: - 空白状态

struct EmptyStateView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("把视频拖到这里")
                .font(.title2)
            Text("也可以用菜单“文件 > 打开…”（⌘O），或者把视频拖到 Dock 图标上")
                .foregroundStyle(.secondary)
            Spacer()
            Divider()
            ToolStatusView(model: model)
        }
        .padding(24)
    }
}

// MARK: - 加载和错误

struct LoadStateOverlay: View {
    let model: AppModel

    var body: some View {
        switch model.loadState {
        case .idle:
            EmptyView()
        case .loading(let fileName, let message, let jobID):
            panel {
                Text(fileName).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if jobID != nil, let progress = model.loadingProgress {
                    ProgressView(value: progress) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("取消") { model.cancelLoading() }
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let message, let log):
            panel {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.yellow)
                Text(message)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    if let log {
                        Button("复制完整命令和日志") { AppModel.copyToPasteboard(log) }
                    }
                    Button("好") { model.dismissError() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(24)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
            .padding(24)
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
