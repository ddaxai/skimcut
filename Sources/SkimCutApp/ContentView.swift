import SkimCore
import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var isDropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let player = model.player {
                    PlayerScreen(player: player, cut: model.cut, model: model)
                } else {
                    EmptyStateView(model: model)
                }
                LoadStateOverlay(model: model)
            }
            if !model.exports.isEmpty {
                Divider()
                ExportsView(model: model)
            }
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
            // 字幕文件加进字幕面板；一个视频打开；多个视频放进批量统一音量窗口。
            model.handleDrop(urls.filter(\.isFileURL))
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .task {
            await model.checkTools()
        }
        .onAppear { openBatchWindowIfRequested() }
        .onChange(of: model.pendingBatchWindow) { openBatchWindowIfRequested() }
    }

    private func openBatchWindowIfRequested() {
        guard model.pendingBatchWindow else { return }
        model.pendingBatchWindow = false
        openWindow(id: BatchWindow.windowID)
    }
}

// MARK: - 播放界面

struct PlayerScreen: View {
    let player: PlayerController
    let cut: CutController?
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(controller: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TransportBar(player: player)
            TimelineStrip(controller: player)
                .frame(height: TimelineMetrics.totalHeight)
                .overlay(alignment: .topLeading) { PlayheadActions(player: player, model: model) }
            BottomPanelSwitcher(player: player, cut: cut, model: model)
        }
        .background(Color.black)
    }
}

/// 暂停时显示在播放头（黄线）旁边的两个小按钮：把播放头的位置填进剪切的开始或结束。
/// 放在时间轴上方的刻度那一条里，不挡缩略图；靠近右边缘时放到黄线左边。
///
/// 吸附到转场后，旁边多一行小字（“已吸附：黑屏 0.52 秒”），两个按钮自动取转场正确的那一边：
/// “设为开始”取转场之后的第一帧，“设为结束”取转场之前（不含黑屏）。
struct PlayheadActions: View {
    let player: PlayerController
    let model: AppModel

    /// 两个按钮大约的总宽度（用来决定放在黄线左边还是右边）。
    private static let buttonsWidth: CGFloat = 132

    var body: some View {
        GeometryReader { geo in
            let x = CGFloat(player.timeline.x(for: player.playhead))
            if player.mode == .paused, x >= 0, x <= geo.size.width {
                let status = statusText
                // 中文小字大约 11 点一个字。
                let width = Self.buttonsWidth + (status.map { CGFloat($0.count) * 11 + 18 } ?? 0)
                let onRight = x + 6 + width <= geo.size.width
                HStack(spacing: 4) {
                    Button("设为开始") {
                        player.markInAtPlayhead()
                        model.bottomPanel = .cut
                    }
                    .help(startHelp)
                    Button("设为结束") {
                        player.markOutAtPlayhead()
                        model.bottomPanel = .cut
                    }
                    .help(endHelp)
                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.65), in: Capsule())
                    }
                }
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .position(
                    x: onRight ? x + 6 + width / 2 : x - 6 - width / 2,
                    y: TimelineMetrics.rulerHeight / 2)
            }
        }
    }

    private var statusText: String? {
        switch player.currentSnapStatus {
        case .searching?: return "正在找转场…"
        case .snapped(let t, _)?: return "已吸附：\(t.displayName)"
        case .notFound?: return "附近没有转场"
        case nil: return nil
        }
    }

    private var startHelp: String {
        if let t = player.snappedTransition {
            return "设为转场之后的第一帧 \(Timecode.format(t.inPoint))（键盘 I）"
        }
        return "把黄线的位置设为剪切的开始（键盘 I）"
    }

    private var endHelp: String {
        if let t = player.snappedTransition {
            return t.kind == .black
                ? "设为黑屏开始的地方 \(Timecode.format(t.outPoint))，剪出来的片段不带黑屏（键盘 O）"
                : "设为画面切换的地方 \(Timecode.format(t.outPoint))（键盘 O）"
        }
        return "把黄线的位置设为剪切的结束（键盘 O）"
    }
}

/// 时间轴下面的面板：剪切 / 字幕 / 音量 / 信息 / 一次导出。
struct BottomPanelSwitcher: View {
    let player: PlayerController
    let cut: CutController?
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.bottomPanel) {
                    ForEach(BottomPanel.allCases) { panel in
                        Text(panel.title).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .background(.bar)

            switch model.bottomPanel {
            case .cut:
                if let cut {
                    CutPanel(player: player, cut: cut, model: model)
                }
            case .subtitles:
                if let subtitles = model.subtitles {
                    SubtitlePanel(player: player, subtitles: subtitles, model: model)
                }
            case .volume:
                if let volume = model.volume {
                    VolumePanel(player: player, volume: volume, model: model)
                }
            case .info:
                if let info = model.info {
                    InfoPanel(info: info, model: model)
                }
            case .exportAll:
                if let cut, let volume = model.volume, let subtitles = model.subtitles, let options = model.exportAllOptions {
                    ExportAllPanel(
                        player: player, cut: cut, volume: volume, subtitles: subtitles, options: options, model: model)
                }
            }
        }
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

            if !player.selection.isFull {
                SelectionSummary(player: player)
            }

            if player.strategy != .native {
                Label(player.strategy == .remux ? "预览：转封装" : "预览：低分辨率代理", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("AVPlayer 不能直接播放原文件，这里播放的是临时预览文件。导出时永远使用原文件，关闭视频时临时文件会被删除。")
            }

            Toggle("吸附转场", isOn: Binding(
                get: { player.snappingEnabled },
                set: { if $0 != player.snappingEnabled { player.toggleSnapping() } }))
                .toggleStyle(.button)
                .controlSize(.small)
                .focusable(false)
                .help("打开时，点击时间轴后黄线会吸附到附近的转场（黑屏、画面切换）。快捷键 N")

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

/// 选区的起点、终点和时长（按 I / O 或拖动时间轴两端的手柄设置）。
struct SelectionSummary: View {
    let player: PlayerController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timeline.selection")
                .foregroundStyle(.secondary)
            Text("\(Timecode.format(player.selection.start)) – \(Timecode.format(player.selection.end))")
                .font(.system(.body, design: .monospaced))
            Text("时长 \(Timecode.format(player.selection.length))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                player.resetSelection()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("清除选区（恢复为整段）")
        }
        .help("选中的区间：按 I / O 设起点 / 终点，或拖动时间轴两端的白色手柄")
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
