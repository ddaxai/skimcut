import SkimCore
import SwiftUI

/// 精确剪切面板：起点 / 终点（或时长）输入框、模式、导出前的提示、多个区间的列表。
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
    @FocusState private var focused: Field?

    /// 导出前提示的刷新键：区间或模式变了就重新规划。
    private struct PlanKey: Equatable {
        var range: CutRange
        var mode: CutMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("起点")
                timeField($startText, invalid: startInvalid, field: .start)

                Picker("", selection: $useDuration) {
                    Text("终点").tag(false)
                    Text("时长").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                timeField($endText, invalid: endInvalid, field: .end)

                Picker("模式", selection: $cut.mode) {
                    ForEach(CutMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer(minLength: 8)

                Button("添加到列表") {
                    cut.addRange(player.selectedRange)
                }
                .help("把当前区间存进列表，可以一次导出多个区间（每个区间一个文件）")

                Button("导出") {
                    model.exportCuts(source: cut.source, ranges: [player.selectedRange], mode: cut.mode)
                }
                .help("把当前区间另存为新文件（原文件不变）。快捷键 ⌘E")
            }

            summaryView

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
