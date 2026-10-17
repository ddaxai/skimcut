import Foundation
import Observation
import SkimCore

/// 信息面板的状态：分组的视频信息、录制时间 / 文件日期的修改、标题和描述。
///
/// 修改会直接改原文件，所以每次都先让用户确认（由面板弹窗）。
@MainActor
@Observable
final class InfoController {
    /// 一次待确认的修改。
    struct PendingEdit: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let run: @MainActor () -> Void
    }

    let source: URL
    private(set) var metadata: MediaMetadata?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var loadError: String?
    /// 上一次修改的结果。
    private(set) var resultMessage: String?
    private(set) var errorMessage: String?
    private(set) var errorLog: String?

    /// 日期选择器里的时间点（显示为 `timeZone` 里的本地时间）。
    var date = Date()
    var timeZone: TimeZone = .current
    var titleText = ""
    var descriptionText = ""

    var pendingEdit: PendingEdit?

    /// 修改成功后调用（重新打开正在播放的视频），带上要显示的结果。
    @ObservationIgnored var onFileChanged: ((URL, String) -> Void)?

    init(source: URL) {
        self.source = source
    }

    var kind: ContainerKind { ContainerKind.of(source) }

    /// 读取信息（第一次显示面板时）。
    func load() async {
        guard metadata == nil, !isLoading else { return }
        await reload(resetFields: true)
    }

    private func reload(resetFields: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let m = try await MetadataReader.read(source)
            metadata = m
            loadError = nil
            if resetFields { resetFieldsFromMetadata() }
        } catch {
            loadError = Self.describe(error).message
        }
    }

    /// 选择器的初始值：录制时间（用它自己的时区）；没有时用文件日期中较早的一个和这台电脑的时区。
    func resetFieldsFromMetadata() {
        guard let m = metadata else { return }
        if let recording = m.recordingDate {
            date = recording.date
            timeZone = TimeZones.zone(forOffset: recording.utcOffset, at: recording.date)
        } else {
            date = m.fileDates.earliest ?? Date()
            timeZone = .current
        }
        titleText = m.title ?? ""
        descriptionText = m.description ?? ""
    }

    var selectedDate: QuickTimeDate { .inZone(date, timeZone) }

    /// 重新打开视频后显示上一次修改的结果。
    func showResult(_ message: String) {
        resultMessage = message
    }

    // MARK: - 修改（先确认）

    func request(_ operation: DateOperation) {
        let name = source.lastPathComponent
        var fields: String
        switch operation {
        case .setAll(let d):
            fields = kind.canWriteEmbedded
                ? "录制时间和文件日期都设为 \(DateInput.display(d))。"
                : "这个格式不能写录制时间，只把文件日期设为 \(DateInput.display(d))。"
        case .setEmbedded(let d):
            fields = "录制时间设为 \(DateInput.display(d))（文件日期不变）。"
        case .setFile(let d):
            fields = "文件的创建日期和修改日期设为 \(DateInput.display(.inZone(d, timeZone)))。"
        case .embeddedToFile:
            fields = "把录制时间写进文件的创建日期和修改日期。"
        case .fileToEmbedded:
            fields = "把文件日期（创建和修改中较早的一个）写进录制时间，时区 \(TimeZones.label(timeZone, at: date))。"
        }
        if !FileDates.canWriteCreation, fields.contains("创建") { fields += "（这个系统不能改创建日期。）" }
        pendingEdit = PendingEdit(
            title: "修改“\(name)”？",
            message: "会直接修改原文件，不生成新文件。\n\(fields)",
            run: { [weak self] in self?.perform(operation) })
    }

    func requestSaveText() {
        guard let m = metadata else { return }
        let title: String? = titleText == (m.title ?? "") ? nil : titleText
        let description: String? = descriptionText == (m.description ?? "") ? nil : descriptionText
        guard title != nil || description != nil else {
            resultMessage = "标题和描述没有变化。"
            return
        }
        var changes: [String] = []
        if let title { changes.append(title.isEmpty ? "删除标题" : "标题改为“\(title)”") }
        if let description { changes.append(description.isEmpty ? "删除描述" : "修改描述") }
        pendingEdit = PendingEdit(
            title: "修改“\(source.lastPathComponent)”？",
            message: "会直接修改原文件，不生成新文件。\n\(changes.joined(separator: "，"))。",
            run: { [weak self] in self?.performSaveText(title: title, description: description) })
    }

    var hasTextChanges: Bool {
        guard let m = metadata else { return false }
        return titleText != (m.title ?? "") || descriptionText != (m.description ?? "")
    }

    private func perform(_ operation: DateOperation) {
        run { editor in
            let change = try await editor.apply(operation, to: self.source)
            var parts: [String] = []
            if let e = change.embedded { parts.append("录制时间 \(DateInput.display(e))") }
            if let f = change.file { parts.append("文件日期 \(DateInput.display(.inZone(f, self.timeZone)))") }
            return "已写入并核对：" + parts.joined(separator: "，") + (change.note.map { "。" + $0 } ?? "")
        }
    }

    private func performSaveText(title: String?, description: String?) {
        run { editor in
            try await editor.setText(title: title, description: description, on: self.source)
            return "标题和描述已写入并核对。"
        }
    }

    private func run(_ body: @escaping @MainActor @Sendable (MetadataEditor) async throws -> String) {
        guard !isWorking else { return }
        isWorking = true
        resultMessage = nil
        errorMessage = nil
        errorLog = nil
        Task { @MainActor [self] in
            defer { isWorking = false }
            do {
                let message = try await body(MetadataEditor())
                await reload(resetFields: true)
                resultMessage = message
                onFileChanged?(source, message)
            } catch {
                let (message, log) = Self.describe(error)
                errorMessage = message
                errorLog = log
                await reload(resetFields: false)
            }
        }
    }

    static func describe(_ error: Error) -> (message: String, log: String?) {
        switch JobStatus.outcome(for: error) {
        case .failed(let message, let log): return (message, log)
        default: return ("已取消", nil)
        }
    }
}

/// 时区选择器的选项。
enum TimeZones {
    /// 常用时区（加上这台电脑的时区）。
    static var common: [TimeZone] {
        let ids = [
            "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo", "Asia/Seoul", "Asia/Singapore",
            "Asia/Bangkok", "Asia/Dubai", "Europe/London", "Europe/Paris", "Europe/Moscow",
            "America/New_York", "America/Chicago", "America/Los_Angeles", "Australia/Sydney", "UTC",
        ]
        var zones = [TimeZone.current]
        for id in ids {
            if let z = TimeZone(identifier: id), !zones.contains(where: { $0.identifier == z.identifier }) {
                zones.append(z)
            }
        }
        return zones
    }

    /// 文件里只有偏移：这台电脑的时区在那一天正好是这个偏移时用它（夏令时也对），否则用固定偏移。
    static func zone(forOffset offset: Int, at date: Date) -> TimeZone {
        if TimeZone.current.secondsFromGMT(for: date) == offset { return .current }
        if let match = common.first(where: { $0.secondsFromGMT(for: date) == offset }) { return match }
        return TimeZone(secondsFromGMT: offset) ?? .current
    }

    /// `上海（+08:00）`
    static func label(_ zone: TimeZone, at date: Date) -> String {
        let offset = DateInput.offsetString(zone.secondsFromGMT(for: date))
        let name = zone.localizedName(for: .shortGeneric, locale: Locale(identifier: "zh_CN"))
            ?? zone.identifier
        let current = zone.identifier == TimeZone.current.identifier ? "（这台电脑）" : ""
        return "\(name) \(offset)\(current)"
    }
}
