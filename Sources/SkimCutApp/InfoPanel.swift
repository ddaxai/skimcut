import SkimCore
import SwiftUI

/// 信息面板。平时只显示分辨率、画质、大小、时长和几个日期，右边一个时间选择器、三个勾选框和“修改”按钮；
/// 标题和描述、日期同步、ExifTool 的全部信息收在“更多”里。
struct InfoPanel: View {
    @Bindable var info: InfoController
    let model: AppModel
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                summaryView
                    .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                Divider()
                dateEditor
                    .frame(width: 440)
            }
            DisclosureGroup("更多（标题和描述、日期同步、全部信息）", isExpanded: $showMore) {
                HStack(alignment: .top, spacing: 16) {
                    sectionsView
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: 170)
                    Divider()
                    moreEditor
                        .frame(width: 440)
                }
                .padding(.top, 4)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task { await info.load() }
        .alert(
            info.pendingEdit?.title ?? "",
            isPresented: Binding(get: { info.pendingEdit != nil }, set: { if !$0 { info.pendingEdit = nil } }),
            presenting: info.pendingEdit
        ) { edit in
            Button("修改原文件") { edit.run() }
            Button("取消", role: .cancel) {}
        } message: { edit in
            Text(edit.message)
        }
    }

    // MARK: - 常用信息

    @ViewBuilder
    private var summaryView: some View {
        if let m = info.metadata {
            let s = info.summary
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("分辨率", s?.resolution ?? "—")
                row("画质", s?.quality ?? "—")
                row("大小", s?.sizeText ?? "—")
                row("时长", s?.duration.map { Timecode.format($0) } ?? "—")
                GridRow { Divider().gridCellColumns(2) }
                GridRow {
                    Text("拍摄日期").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(m.recordingDate.map(DateInput.display) ?? "没有").monospacedDigit()
                        if m.recordingDate != nil, !m.recordingDateHasTimeZone, m.kind == .quickTime {
                            Text("（没有时区，“照片”可能显示错误）").foregroundStyle(.orange)
                        }
                    }
                    .help("视频里记录的拍摄时间，“照片” App 用它排序")
                }
                row("创建日期", localText(m.fileDates.creation))
                row("修改日期", localText(m.fileDates.modification))
                GridRow {
                    Text("添加日期").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(localText(m.fileDates.added)).monospacedDigit()
                        Text("（系统记录，不能改）").font(.caption).foregroundStyle(.secondary)
                    }
                    .help("文件放进这个文件夹的时间，由 macOS 自动记录，任何 App 都改不了")
                }
            }
        } else if let error = info.loadError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func localText(_ date: Date?) -> String {
        date.map { Self.localFormatter.string(from: $0) } ?? "—"
    }

    // MARK: - 修改日期

    private var dateEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("修改日期").font(.headline)
            DateTimeZoneEditor(date: $info.date, timeZone: $info.timeZone)
            HStack(spacing: 14) {
                Toggle("创建日期", isOn: $info.changeCreation)
                Toggle("修改日期", isOn: $info.changeModification)
                Toggle("拍摄日期", isOn: $info.changeRecording)
                    .disabled(!info.kind.canWriteEmbedded)
                    .help(info.kind.canWriteEmbedded ? "“照片” App 用的时间" : "这个格式不能写拍摄日期")
            }
            HStack(spacing: 8) {
                Button("修改") {
                    info.request(.setSelected(
                        info.selectedDate, creation: info.changeCreation, modification: info.changeModification,
                        recording: info.changeRecording && info.kind.canWriteEmbedded))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(info.changeCreation || info.changeModification || (info.changeRecording && info.kind.canWriteEmbedded)))
                Button("批量…") { model.openBatchWindow(.dates) }
                    .help("一次修改多个视频的日期")
                Spacer(minLength: 0)
            }
            Text("创建日期、修改日期：访达里按日期排序用；拍摄日期：“照片” App 用。")
                .font(.caption)
                .foregroundStyle(.secondary)
            status
        }
        .disabled(info.isWorking || info.metadata == nil)
    }

    // MARK: - 更多

    private var moreEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("拍摄日期 → 文件日期") { info.request(.embeddedToFile) }
                    .disabled(info.metadata?.recordingDate == nil)
                    .help("把视频里记录的拍摄时间写进文件的创建日期和修改日期")
                Button("文件日期 → 拍摄日期") { info.request(.fileToEmbedded(info.timeZone)) }
                    .disabled(!info.kind.canWriteEmbedded)
                    .help("用创建日期和修改日期中较早的一个，按上面选的时区写入")
            }
            textFields
        }
        .disabled(info.isWorking || info.metadata == nil)
    }

    // MARK: - 分组信息

    @ViewBuilder
    private var sectionsView: some View {
        if let metadata = info.metadata {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(metadata.sections) { section in
                        DisclosureGroup {
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                                ForEach(section.entries) { entry in
                                    GridRow {
                                        Text(entry.tag)
                                            .foregroundStyle(.secondary)
                                            .help("\(entry.family):\(entry.tag)")
                                        Text(entry.value)
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .font(.system(.caption, design: .monospaced))
                            .padding(.leading, 4)
                        } label: {
                            Text("\(section.group.displayName)（\(section.entries.count)）").font(.headline)
                        }
                    }
                }
            }
        } else if let error = info.loadError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("标题", text: $info.titleText)
                .textFieldStyle(.roundedBorder)
            HStack(alignment: .bottom) {
                TextField("描述 / 注释", text: $info.descriptionText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button("保存标题和描述") { info.requestSaveText() }
                    .disabled(!info.hasTextChanges || !info.kind.canWriteEmbedded)
            }
            if !info.kind.canWriteEmbedded {
                Text("这个格式不能写入录制时间、标题和描述，只能改文件日期。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if info.isWorking {
            HStack {
                ProgressView().controlSize(.small)
                Text("正在写入…").foregroundStyle(.secondary)
            }
        } else if let error = info.errorMessage {
            HStack {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
                if let log = info.errorLog {
                    Button("复制完整命令和日志") { AppModel.copyToPasteboard(log) }
                }
            }
        } else if let result = info.resultMessage {
            Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(2)
        }
    }
}

/// 本地时间 + 时区。选择器显示的是所选时区里的本地时间，写入时按那一天的偏移换算（夏令时也对）。
struct DateTimeZoneEditor: View {
    @Binding var date: Date
    @Binding var timeZone: TimeZone

    var body: some View {
        HStack(spacing: 8) {
            // macOS 的选择器只到分钟；秒保留原来的值。
            DatePicker("时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, timeZone)
                .fixedSize()
            Picker("时区", selection: Binding(
                get: { timeZone.identifier },
                set: { id in if let z = TimeZone(identifier: id) { timeZone = z } }
            )) {
                ForEach(zones, id: \.identifier) { zone in
                    Text(TimeZones.label(zone, at: date)).tag(zone.identifier)
                }
            }
            .fixedSize()
        }
    }

    /// 常用时区；当前选的不在里面时（例如文件里的固定偏移）也列出来。
    private var zones: [TimeZone] {
        var list = TimeZones.common
        if !list.contains(where: { $0.identifier == timeZone.identifier }) { list.insert(timeZone, at: 0) }
        return list
    }
}
