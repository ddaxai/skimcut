import SkimCore
import SwiftUI

/// 剪切面板：掐头去尾。拖动时间轴两端的白色手柄，下面实时显示开始 / 结束在原视频里的时间，
/// 也可以直接输入；一个“导出”按钮。模式、时长输入、多个区间收在“更多选项”里。
///
/// 输入框和时间轴的选区双向同步：拖动手柄或按 I / O 时输入框跟着变；
/// 在输入框里按回车或离开输入框时，选区跟着变。
struct CutPanel: View {
    let player: PlayerController
    @Bindable var cut: CutController
    let model: AppModel

    private enum Field: Hashable { case start, end }

    @State private var startText = ""
    @State private var endText = ""
    @State private var useDuration = false
    @State private var startInvalid = false
    @State private var endInvalid = false
    @State private var showMore = false
    @FocusState private var focused: Field?

    /// 导出前提示的刷新键：区间或模式变了就重新规划。
    private struct PlanKey: Equatable {
        var range: CutRange
        var mode: CutMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 14) {
                labeled("开始") { timeField($startText, invalid: startInvalid, field: .start) }
                labeled(useDuration ? "时长" : "结束") { timeField($endText, invalid: endInvalid, field: .end) }
                labeled("剪后时长") {
                    Text(Timecode.format(player.selection.length))
                        .font(.system(.body, design: .monospaced))
                        .padding(.vertical, 3)
                }
                Spacer(minLength: 8)
                Button {
                    model.exportCuts(source: cut.source, ranges: [player.selectedRange], mode: cut.mode)
                } label: {
                    Text("导出").frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(player.selection.isFull)
                .help(player.selection.isFull
                      ? "先拖动时间轴两端的白色手柄（或输入时间）选出要保留的部分"
                      : "把选中的部分另存为新文件（原文件不变）。快捷键 ⌘E")
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("更多选项", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Picker("模式", selection: $cut.mode) {
                            ForEach(CutMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("无损快剪：不重新编码，很快；精确：重新编码，任何格式都精确到帧，但慢很多")
                        Picker("第二个输入框", selection: $useDuration) {
                            Text("填结束时间").tag(false)
                            Text("填时长").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer(minLength: 8)
                        Button("添加到列表") {
                            cut.addRange(player.selectedRange)
                        }
                        .disabled(player.selection.isFull)
                        .help("把当前区间存进列表，可以一次导出多个区间（每个区间一个文件）")
                    }
                    transitionRow
                    summaryView
                }
                .padding(.top, 4)
            }
            .font(.callout)

            if !cut.ranges.isEmpty {
                rangeList
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task(id: PlanKey(range: player.selectedRange, mode: cut.mode)) {
            await cut.refreshSummary(for: player.selectedRange)
        }
        .onAppear { syncTexts() }
        .onChange(of: player.selection) { syncTexts() }
        .onChange(of: useDuration) { syncTexts(force: true) }
        .onChange(of: focused) { old, new in
            // 离开输入框时应用输入的内容。
            if old == .start, new != .start { applyStart() }
            if old == .end, new != .end { applyEnd() }
        }
    }

    // MARK: - 输入框

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    /// 输入框下面的一行说明。
    private var hint: String {
        if player.selection.isFull {
            return "拖动时间轴两端的白色手柄掐头去尾，或者直接输入时间（例如 0:30 表示 30 秒）。"
        }
        if cut.mode == .precise {
            return "精确模式会重新编码，比较慢。只是掐头去尾时用“无损快剪”就够了（在“更多选项”里）。"
        }
        if let summary = cut.summary, let lead = summary.leadInMessage, summary.leadIn > 0 {
            return lead
        }
        return "无损快剪：不重新编码，画质不变，一般十几秒内完成。"
    }

    private func timeField(_ text: Binding<String>, invalid: Bool, field: Field) -> some View {
        TextField("0:00.000", text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(width: 118)
            .focused($focused, equals: field)
            .overlay {
                if invalid {
                    RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: 1.5)
                }
            }
            .help("可以输入 1:23.456、00:01:23.456 或 83.456")
            .onSubmit {
                if field == .start { applyStart() } else { applyEnd() }
                // 等 SwiftUI 处理完这次回车再把键盘交给播放画面；同步调用会被随后的焦点更新抢回去。
                Task { @MainActor in
                    await Task.yield()
                    player.focusPlayer?()
                }
            }
    }

    /// 把选区写进输入框（正在编辑的输入框不动，除非 `force`）。
    private func syncTexts(force: Bool = false) {
        if force || focused != .start {
            startText = Timecode.format(player.selection.start)
            startInvalid = false
        }
        if force || focused != .end {
            endText = Timecode.format(useDuration ? player.selection.length : player.selection.end)
            endInvalid = false
        }
    }

    private func applyStart() {
        guard let t = Timecode.parse(startText), t < player.duration else {
            startInvalid = true
            return
        }
        startInvalid = false
        // 时长模式：保持时长不变，终点跟着起点移动。
        let length = player.selection.length
        player.setSelectionStart(t)
        if useDuration { player.setSelectionEnd(player.selection.start + length) }
        syncTexts(force: true)
    }

    private func applyEnd() {
        guard let t = Timecode.parse(endText), t > 0 else {
            endInvalid = true
            return
        }
        endInvalid = false
        player.setSelectionEnd(useDuration ? player.selection.start + t : t)
        syncTexts(force: true)
    }

    // MARK: - 导出前的提示

    @ViewBuilder
    private var summaryView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if cut.isPlanning {
                ProgressView().controlSize(.mini)
            }
            if let error = cut.planError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let summary = cut.summary {
                VStack(alignment: .leading, spacing: 2) {
                    if let lead = summary.leadInMessage {
                        Label(lead, systemImage: "info.circle")
                    }
                    if let encoder = summary.encoderDescription {
                        Label(encoder, systemImage: "film")
                    }
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("输出：\(summary.outputName)" + (summary.copiesMetadata ? "（复制原文件的元数据）" : ""))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 找出全部转场

    /// 找出全部转场 → 按转场分段加入区间列表。
    @ViewBuilder
    private var transitionRow: some View {
        HStack(spacing: 8) {
            switch player.transitionScan {
            case .idle:
                Button("找出全部转场") { model.findAllTransitions() }
                    .help("在后台把整段视频缩小后分析一遍，在时间轴上标出所有黑屏和画面切换，然后可以按转场分段导出。视频越长越久，可以取消。")
            case .running(let progress):
                ProgressView(value: progress ?? 0)
                    .frame(width: 120)
                Text(progress.map { "正在找转场… \(Int(($0 * 100).rounded()))%" } ?? "正在找转场…")
                    .foregroundStyle(.secondary)
                Button("取消") { model.cancelTransitionScan() }
            case .done(let count):
                if count == 0 {
                    Text("没有找到转场")
                        .foregroundStyle(.secondary)
                } else {
                    let segments = player.transitionSegments
                    Text("找到 \(count) 个转场（时间轴上的青色线）")
                    Button("按转场分成 \(segments.count) 段，加入列表") {
                        cut.addRanges(segments)
                    }
                    .disabled(segments.count < 2)
                    .help("每一段导出成一个文件；黑屏不包含在任何一段里。加入列表后点“全部导出”。")
                }
            case .failed(let message):
                Text("找转场失败：\(message)")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("重试") { model.findAllTransitions() }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 多个区间

    private var rangeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("区间列表（\(cut.ranges.count) 个，每个导出成一个文件）")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("全部清除") { cut.removeAllRanges() }
                Button("全部导出") {
                    model.exportCuts(source: cut.source, ranges: cut.ranges, mode: cut.mode)
                }
            }
            ForEach(Array(cut.ranges.enumerated()), id: \.offset) { index, range in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Button {
                        player.select(range)
                    } label: {
                        Text("\(Timecode.format(range.start)) – \(Timecode.format(range.end))")
                            .font(.system(.body, design: .monospaced))
                    }
                    .buttonStyle(.link)
                    .help("在时间轴上选中这个区间")
                    Text("时长 \(Timecode.format(range.duration))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        cut.removeRange(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("从列表里去掉")
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 导出任务列表：进度、取消、完成后在 Finder 中显示、失败时复制完整命令和日志。
struct ExportsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("导出").font(.headline)
                Spacer()
                Button("清除已完成") { model.clearFinishedExports() }
                    .disabled(!model.exports.contains { model.job($0.id)?.status.isFinished ?? false })
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.exports) { record in
                        ExportRow(record: record, job: model.job(record.id), model: model)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ExportRow: View {
    let record: ExportRecord
    let job: JobSnapshot?
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIcon
                Text(record.output?.lastPathComponent ?? record.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.title)
                Spacer()
                actions
            }
            switch job?.status {
            case .running?:
                if let progress = job?.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            case .failed(let message, _)?:
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            default:
                EmptyView()
            }
            if let note = record.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job?.status {
        case .succeeded?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed?:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled?:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .running?:
            Image(systemName: "scissors").foregroundStyle(Color.accentColor)
        default:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job?.status {
        case .queued?, .running?, nil:
            Button("取消") { model.cancelJob(record.id) }
        case .succeeded?:
            if let output = record.output {
                Button("在 Finder 中显示") { AppModel.revealInFinder(output) }
            }
        case .failed(_, let log)?:
            if let log {
                Button("复制完整命令和日志") { AppModel.copyToPasteboard(log) }
            }
        case .cancelled?:
            Text("已取消").foregroundStyle(.secondary)
        }
    }
}
