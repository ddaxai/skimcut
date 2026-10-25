import SkimCore
import SwiftUI

/// 信息面板：左边是分组的视频信息，右边修改录制时间 / 文件日期、标题和描述。
struct InfoPanel: View {
    @Bindable var info: InfoController
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sectionsView
                .frame(minWidth: 320, maxWidth: .infinity)
            Divider()
            editor
                .frame(width: 430)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 230)
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

    // MARK: - 修改

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = info.metadata {
                currentDates(m)
            }
            DateTimeZoneEditor(date: $info.date, timeZone: $info.timeZone)
            HStack(spacing: 6) {
                Button("全部设为这个时间") { info.request(.setAll(info.selectedDate)) }
                    .help("录制时间、文件创建日期、文件修改日期都设为这个时间")
                Button("只改录制时间") { info.request(.setEmbedded(info.selectedDate)) }
                    .disabled(!info.kind.canWriteEmbedded)
                Button("只改文件日期") { info.request(.setFile(info.date)) }
            }
            HStack(spacing: 6) {
                Button("录制时间 → 文件日期") { info.request(.embeddedToFile) }
                    .disabled(info.metadata?.recordingDate == nil)
                Button("文件日期 → 录制时间") { info.request(.fileToEmbedded(info.timeZone)) }
                    .disabled(!info.kind.canWriteEmbedded)
                    .help("用创建日期和修改日期中较早的一个，按上面选的时区写入")
                Spacer(minLength: 0)
                Button("批量修改日期…") { model.openBatchWindow(.dates) }
            }
            .disabled(info.isWorking)
            Divider()
            textFields
            status
        }
        .disabled(info.isWorking || info.metadata == nil)
    }

    private func currentDates(_ m: MediaMetadata) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("录制时间").foregroundStyle(.secondary)
                if let r = m.recordingDate {
                    Text(DateInput.display(r)).monospacedDigit()
                    if !m.recordingDateHasTimeZone {
                        Text(m.kind == .matroska ? "（MKV 只存 UTC）" : "（没有时区，“照片”可能显示错误）")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("没有").foregroundStyle(.orange)
                }
            }
            HStack(spacing: 4) {
                Text("文件创建").foregroundStyle(.secondary)
                Text(m.fileDates.creation.map { DateInput.display(.inZone($0, .current)) } ?? "—").monospacedDigit()
                Text("修改").foregroundStyle(.secondary)
                Text(m.fileDates.modification.map { DateInput.display(.inZone($0, .current)) } ?? "—").monospacedDigit()
            }
            .font(.caption)
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
