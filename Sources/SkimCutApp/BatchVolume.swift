import AppKit
import Observation
import SkimCore
import SwiftUI
import UniformTypeIdentifiers

/// 批量统一音量：一次加入多个视频，逐个检测，一键全部处理成相同的音量。
///
/// 检测在“分析”队列里一次一个；处理在导出队列里一次一个。原文件永远不变。
@MainActor
@Observable
final class BatchVolumeController {
    enum State: Equatable {
        case waiting
        case detecting(Double?)
        case detected
        case queued
        case processing(Double?)
        case done(VolumeResult)
        case failed(message: String, log: String?)
        case cancelled

        var isBusy: Bool {
            switch self {
            case .waiting, .detecting, .queued, .processing: return true
            case .detected, .done, .failed, .cancelled: return false
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var stats: LoudnessStats?
        var state: State = .waiting
    }

    private(set) var items: [Item] = []
    /// 批量处理的选项（没有局部压低）。
    var options = AppSettings.defaultNormalizeOptions

    @ObservationIgnored private let queue: TaskQueue
    @ObservationIgnored private let analysisQueue: TaskQueue
    /// 每个项目的任务（用于取消）。
    @ObservationIgnored private var jobs: [UUID: [(queue: TaskQueue, id: JobID)]] = [:]

    init(queue: TaskQueue, analysisQueue: TaskQueue) {
        self.queue = queue
        self.analysisQueue = analysisQueue
    }

    var isBusy: Bool { items.contains { $0.state.isBusy } }
    var canProcess: Bool { items.contains { canProcess($0) } }

    private func canProcess(_ item: Item) -> Bool {
        switch item.state {
        case .detected, .failed, .cancelled: return true
        default: return false
        }
    }

    // MARK: - 列表

    /// 加入视频（已经在列表里的跳过），并在后台逐个检测。
    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        for url in urls where url.isFileURL && !existing.contains(url.standardizedFileURL) {
            let item = Item(url: url)
            items.append(item)
            detect(item)
        }
    }

    func remove(_ ids: Set<UUID>) {
        for id in ids { cancelJobs(id) }
        items.removeAll { ids.contains($0.id) }
    }

    /// 去掉已经处理完（或跳过）的项目。
    func removeFinished() {
        items.removeAll {
            if case .done = $0.state { return true }
            return false
        }
    }

    // MARK: - 检测

    private func detect(_ item: Item) {
        let id = item.id
        let url = item.url
        let queue = analysisQueue
        Task { @MainActor [weak self] in
            let job = await queue.enqueue(title: "检测响度：\(url.lastPathComponent)") { [weak self] context in
                let batch = self
                await batch?.detecting(id, nil)
                do {
                    let info = try await MediaInfo.probe(url)
                    guard !info.audioStreams.isEmpty else { throw LoudnessError.noAudio }
                    let analysis = try await VolumeExporter().analyze(url, duration: info.bestDuration) { p in
                        context.report(progress: p)
                        Task { @MainActor in batch?.detecting(id, p) }
                    }
                    await batch?.detected(id, analysis.stats)
                } catch {
                    await batch?.failed(id, error)
                    throw error
                }
            }
            self?.jobs[id, default: []].append((queue, job))
        }
    }

    // MARK: - 处理

    /// 把所有还没处理的视频加入处理队列。
    func processAll() {
        for item in items where canProcess(item) {
            process(item)
        }
    }

    private func process(_ item: Item) {
        let id = item.id
        set(id, .queued)
        let job = VolumeJob(source: item.url, options: options, outputDirectory: AppSettings.outputDirectory)
        let title = "统一音量：\(item.url.lastPathComponent)"
        let queue = self.queue
        Task { @MainActor [weak self] in
            let jobID = await queue.enqueue(title: title) { [weak self] context in
                let batch = self
                await batch?.processing(id, nil)
                do {
                    let result = try await VolumeExporter().export(job) { p in
                        context.report(progress: p)
                        Task { @MainActor in batch?.processing(id, p) }
                    }
                    await batch?.done(id, result)
                } catch {
                    await batch?.failed(id, error)
                    throw error
                }
            }
            self?.jobs[id, default: []].append((queue, jobID))
        }
    }

    /// 取消全部排队和进行中的任务。
    func cancelAll() {
        for item in items where item.state.isBusy {
            cancelJobs(item.id)
            set(item.id, item.stats == nil ? .cancelled : .detected)
        }
    }

    private func cancelJobs(_ id: UUID) {
        for job in jobs.removeValue(forKey: id) ?? [] {
            Task { await job.queue.cancel(job.id) }
        }
    }

    // MARK: - 状态（任务结束得比取消晚时，不把状态改回“进行中”）

    private func detecting(_ id: UUID, _ p: Double?) {
        guard let item = item(id) else { return }
        switch item.state {
        case .waiting, .detecting: set(id, .detecting(p))
        default: break
        }
    }

    private func detected(_ id: UUID, _ stats: LoudnessStats) {
        guard let index = index(id) else { return }
        items[index].stats = stats
        switch items[index].state {
        case .waiting, .detecting, .cancelled: items[index].state = .detected
        default: break
        }
    }

    private func processing(_ id: UUID, _ p: Double?) {
        guard let item = item(id) else { return }
        switch item.state {
        case .queued, .processing: set(id, .processing(p))
        default: break
        }
    }

    /// 新文件已经写好：不管是否点过取消，都显示出来。
    private func done(_ id: UUID, _ result: VolumeResult) {
        guard let index = index(id) else { return }
        items[index].stats = result.before
        items[index].state = .done(result)
    }

    private func failed(_ id: UUID, _ error: Error) {
        guard let item = item(id), item.state.isBusy else { return }
        switch JobStatus.outcome(for: error) {
        case .failed(let message, let log):
            set(id, .failed(message: message, log: log))
        default:
            set(id, item.stats == nil ? .cancelled : .detected)
        }
    }

    private func index(_ id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func item(_ id: UUID) -> Item? {
        index(id).map { items[$0] }
    }

    private func set(_ id: UUID, _ state: State) {
        guard let index = index(id) else { return }
        items[index].state = state
    }
}

/// 批量统一音量窗口。
struct BatchVolumeView: View {
    static let windowID = "batch-volume"

    @Bindable var batch: BatchVolumeController
    @State private var selection = Set<UUID>()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            optionsRow
            table
            bottomRow
        }
        .padding(14)
        .frame(minWidth: 820, minHeight: 420)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            batch.add(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Stepper(value: $batch.options.targetLoudness, in: -30...(-10), step: 0.5) {
                    Text("目标 \(number(batch.options.targetLoudness)) LUFS")
                }
                .fixedSize()
                Stepper(value: $batch.options.truePeak, in: -6...0, step: 0.5) {
                    Text("真峰值 ≤ \(number(batch.options.truePeak)) dBTP")
                }
                .fixedSize()
                Picker("强度", selection: $batch.options.preset) {
                    ForEach(LoudnessPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("减少喷麦声", isOn: $batch.options.highpass)
                Toggle("削波修复", isOn: $batch.options.declip)
                    .help("只能改善，不能完全恢复；处理比较慢")
            }
            Text("把视频拖进这个窗口。每个视频处理后都写成新文件（原名_norm），视频直接复制，只重新编码音频；已经接近目标的视频跳过。输出位置：\(outputLocation)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputLocation: String {
        AppSettings.outputDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "原文件旁边"
    }

    private var table: some View {
        Table(batch.items, selection: $selection) {
            TableColumn("文件") { item in
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
            }
            .width(min: 180, ideal: 260)
            TableColumn("响度") { item in
                Text(item.stats.map { String(format: "%.1f LUFS", $0.integrated) } ?? "—").monospacedDigit()
            }
            .width(90)
            TableColumn("真峰值") { item in
                Text(item.stats.map { String(format: "%.1f dBTP", $0.truePeak) } ?? "—").monospacedDigit()
            }
            .width(90)
            TableColumn("范围") { item in
                Text(item.stats.map { String(format: "%.1f LU", $0.range) } ?? "—").monospacedDigit()
            }
            .width(70)
            TableColumn("状态") { item in
                BatchStatusView(state: item.state)
            }
            .width(min: 220, ideal: 320)
        }
        .overlay {
            if batch.items.isEmpty {
                Text("把要统一音量的视频拖到这里（可以一次拖入多个）")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bottomRow: some View {
        HStack {
            Button("添加视频…") { chooseFiles() }
            Button("移除所选") {
                batch.remove(selection)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
            Button("清除已完成") { batch.removeFinished() }
            Spacer()
            if batch.isBusy {
                Button("全部取消") { batch.cancelAll() }
            }
            Button("全部统一处理") { batch.processAll() }
                .keyboardShortcut(.defaultAction)
                .disabled(!batch.canProcess)
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

    private func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private struct BatchStatusView: View {
    let state: BatchVolumeController.State

    var body: some View {
        switch state {
        case .waiting:
            Text("等待检测").foregroundStyle(.secondary)
        case .detecting(let p):
            progress("检测中", p)
        case .detected:
            Text("已检测").foregroundStyle(.secondary)
        case .queued:
            Text("等待处理").foregroundStyle(.secondary)
        case .processing(let p):
            progress("处理中", p)
        case .done(let result):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let after = result.after {
                    Text(String(format: "完成：%.1f → %.1f LUFS", result.before.integrated, after.integrated))
                        .help(result.comparison + (result.note.map { "\n" + $0 } ?? ""))
                } else {
                    Text("已接近目标，跳过").help(result.comparison)
                }
                if let output = result.output {
                    Button("在 Finder 中显示") { AppModel.revealInFinder(output) }
                        .buttonStyle(.link)
                }
            }
        case .failed(let message, let log):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).lineLimit(1).help(message)
                if let log {
                    Button("复制日志") { AppModel.copyToPasteboard(log) }
                        .buttonStyle(.link)
                        .help("复制完整命令和日志")
                }
            }
        case .cancelled:
            Text("已取消").foregroundStyle(.secondary)
        }
    }

    private func progress(_ title: String, _ p: Double?) -> some View {
        HStack(spacing: 6) {
            if let p {
                ProgressView(value: p).frame(width: 100)
                Text("\(title) \(Int(p * 100))%").monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                Text(title)
            }
        }
    }
}
