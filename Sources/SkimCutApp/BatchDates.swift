import AppKit
import Observation
import SkimCore
import SwiftUI
import UniformTypeIdentifiers

/// 批量修改日期：同一个操作用在列表里的每个视频上（直接修改原文件，执行前确认）。
@MainActor
@Observable
final class BatchDatesController {
    enum Choice: String, CaseIterable, Identifiable {
        case setAll, setEmbedded, setFile, embeddedToFile, fileToEmbedded

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .setAll: return "全部日期设为这个时间"
            case .setEmbedded: return "只改录制时间"
            case .setFile: return "只改文件日期"
            case .embeddedToFile: return "录制时间 → 文件日期"
            case .fileToEmbedded: return "文件日期 → 录制时间"
            }
        }

        /// 需不需要选时间（同步操作只用时区或什么都不用）。
        var usesDate: Bool { [.setAll, .setEmbedded, .setFile].contains(self) }
    }

    enum State: Equatable {
        case reading
        case ready
        case working
        case done(String)
        case failed(message: String, log: String?)
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var recording: QuickTimeDate?
        var hasZone = false
        var fileModified: Date?
        var state: State = .reading
    }

    private(set) var items: [Item] = []
    var choice: Choice = .setAll
    var date = Date()
    var timeZone: TimeZone = .current
    private(set) var isRunning = false

    /// 修改成功后调用（主窗口正在播放这个视频时重新打开）。
    @ObservationIgnored var onFileChanged: ((URL) -> Void)?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    var operation: DateOperation {
        let d = QuickTimeDate.inZone(date, timeZone)
        switch choice {
        case .setAll: return .setAll(d)
        case .setEmbedded: return .setEmbedded(d)
        case .setFile: return .setFile(date)
        case .embeddedToFile: return .embeddedToFile
        case .fileToEmbedded: return .fileToEmbedded(timeZone)
        }
    }

    var confirmationMessage: String {
        var what = choice.displayName
        if choice.usesDate { what += "：\(DateInput.display(QuickTimeDate.inZone(date, timeZone)))" }
        if choice == .fileToEmbedded { what += "（时区 \(TimeZones.label(timeZone, at: date))）" }
        return "会直接修改这 \(items.count) 个原文件，不生成新文件。\n\(what)\nAVI 等格式只能改文件日期。"
    }

    // MARK: - 列表

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        var added: [UUID] = []
        for url in urls where url.isFileURL && !existing.contains(url.standardizedFileURL) {
            let item = Item(url: url)
            items.append(item)
            added.append(item.id)
        }
        Task { @MainActor [weak self] in
            for id in added { await self?.refresh(id) }
        }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
    }

    func removeFinished() {
        items.removeAll {
            if case .done = $0.state { return true }
            return false
        }
    }

    /// 重新读取一个文件的录制时间和文件日期。
    private func refresh(_ id: UUID) async {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        let metadata = try? await MetadataReader.read(url)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].recording = metadata?.recordingDate
        items[index].hasZone = metadata?.recordingDateHasTimeZone ?? false
        items[index].fileModified = metadata?.fileDates.modification ?? (try? FileDates.read(url))?.modification
        if items[index].state == .reading {
            items[index].state = metadata == nil ? .failed(message: "读不到这个文件的信息。", log: nil) : .ready
        }
    }

    // MARK: - 执行

    /// 对列表里的每个文件依次执行（用户已经确认过）。
    func applyAll() {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        let operation = self.operation
        let zone = timeZone
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.runTask = nil
            }
            let editor = MetadataEditor()
            for id in self.items.map(\.id) {
                guard !Task.isCancelled else { break }
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                let url = self.items[index].url
                self.items[index].state = .working
                let state: State
                do {
                    let change = try await editor.apply(operation, to: url)
                    var parts: [String] = []
                    if let e = change.embedded { parts.append("录制时间 \(DateInput.display(e))") }
                    if let f = change.file { parts.append("文件日期 \(DateInput.display(.inZone(f, zone)))") }
                    state = .done(parts.joined(separator: "，") + (change.note == nil ? "" : "（只改了文件日期）"))
                    self.onFileChanged?(url)
                } catch {
                    let (message, log) = InfoController.describe(error)
                    state = .failed(message: message, log: log)
                }
                if let i = self.items.firstIndex(where: { $0.id == id }) { self.items[i].state = state }
                await self.refresh(id)
            }
        }
    }

    func cancel() {
        runTask?.cancel()
    }
}

/// 批量修改日期的页面。
struct BatchDatesView: View {
    @Bindable var batch: BatchDatesController
    @State private var selection = Set<UUID>()
    @State private var isDropTargeted = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("操作", selection: $batch.choice) {
                    ForEach(BatchDatesController.Choice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .fixedSize()
                DateTimeZoneEditor(date: $batch.date, timeZone: $batch.timeZone)
                    .disabled(batch.choice == .embeddedToFile)
            }
            Text("录制时间写进视频内部（MP4/MOV 带时区，“照片” App 用它；MKV 只存 UTC），文件日期是 Finder 里的创建 / 修改日期。“文件日期 → 录制时间”用创建和修改中较早的一个。")
                .font(.caption)
                .foregroundStyle(.secondary)
            table
            HStack {
                Button("添加视频…") { chooseFiles() }
                Button("移除所选") {
                    batch.remove(selection)
                    selection.removeAll()
                }
                .disabled(selection.isEmpty || batch.isRunning)
                Button("清除已完成") { batch.removeFinished() }
                    .disabled(batch.isRunning)
                Spacer()
                if batch.isRunning {
                    Button("停止") { batch.cancel() }
                }
                Button("应用到全部（\(batch.items.count) 个）") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(batch.items.isEmpty || batch.isRunning)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            batch.add(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .alert("修改 \(batch.items.count) 个文件的日期？", isPresented: $confirming) {
            Button("修改原文件") { batch.applyAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(batch.confirmationMessage)
        }
    }

    private var table: some View {
        Table(batch.items, selection: $selection) {
            TableColumn("文件") { item in
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle).help(item.url.path)
            }
            .width(min: 160, ideal: 240)
            TableColumn("录制时间") { item in
                HStack(spacing: 4) {
                    Text(item.recording.map(DateInput.display) ?? "没有").monospacedDigit()
                    if item.recording != nil, !item.hasZone {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("没有时区（UTC）")
                    }
                }
            }
            .width(min: 190, ideal: 210)
            TableColumn("文件修改日期") { item in
                Text(item.fileModified.map { DateInput.display(.inZone($0, .current)) } ?? "—").monospacedDigit()
            }
            .width(min: 190, ideal: 210)
            TableColumn("状态") { item in
                switch item.state {
                case .reading: Text("读取中…").foregroundStyle(.secondary)
                case .ready: Text("—").foregroundStyle(.secondary)
                case .working: ProgressView().controlSize(.small)
                case .done(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1).help(text)
                case .failed(let message, let log):
                    HStack(spacing: 6) {
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(1).help(message)
                        if let log {
                            Button("复制日志") { AppModel.copyToPasteboard(log) }.buttonStyle(.link)
                        }
                    }
                }
            }
            .width(min: 200, ideal: 300)
        }
        .overlay {
            if batch.items.isEmpty {
                Text("把要修改日期的视频拖到这里（可以一次拖入多个）").foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            batch.add(panel.urls)
        }
    }
}
