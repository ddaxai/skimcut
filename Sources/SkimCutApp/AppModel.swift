import AppKit
import Observation
import SkimCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum LoadState: Equatable {
        case idle
        /// 正在打开；`jobID` 不为 nil 时表示正在生成预览文件（可以取消）。
        case loading(fileName: String, message: String, jobID: JobID?)
        case failed(message: String, log: String?)
    }

    /// 当前打开的视频。
    private(set) var player: PlayerController?
    /// 当前视频的剪切面板状态。
    private(set) var cut: CutController?
    /// 当前视频的字幕面板状态。
    private(set) var subtitles: SubtitleController?
    /// 当前视频的音量面板状态。
    private(set) var volume: VolumeController?
    /// 当前视频的信息面板状态。
    private(set) var info: InfoController?
    /// 当前视频的一次导出选项。
    private(set) var exportAllOptions: ExportAllController?
    /// 批量处理窗口：统一音量、修改日期。
    let batch: BatchVolumeController
    let batchDates: BatchDatesController
    var batchTab: BatchTab = .volume
    /// 请求打开批量处理窗口（窗口由界面打开）。
    var pendingBatchWindow = false
    /// 重新打开视频后要回到的播放头位置。
    @ObservationIgnored private var pendingPlayhead: (url: URL, time: Double)?
    /// 重新打开视频后在信息面板里显示的结果。
    @ObservationIgnored private var pendingInfoResult: (url: URL, message: String)?
    /// 时间轴下面显示哪个面板。
    var bottomPanel: BottomPanel = .cut
    /// 导出记录（任务的进度和状态来自 `jobs`）。
    private(set) var exports: [ExportRecord] = []
    private(set) var loadState: LoadState = .idle
    /// 任务队列里的全部任务（用于显示进度）。
    private(set) var jobs: [JobSnapshot] = []
    private(set) var tools: [ToolStatus] = []
    private(set) var isCheckingTools = false

    /// 剪切、导出、生成预览的任务队列（一次一个）。
    let queue: TaskQueue
    /// 响度检测和试听的队列（一次一个），不让导出任务排队等着它们。
    let analysisQueue: TaskQueue
    let previewStore = PreviewFileStore()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// 每次打开换一个新值；旧的加载任务发现自己过期后不再修改状态。
    @ObservationIgnored private var openToken = UUID()
    @ObservationIgnored private var queueObserver: Task<Void, Never>?
    @ObservationIgnored private var analysisObserver: Task<Void, Never>?

    init() {
        // `SkimCutApp` 的属性初始化（创建这个对象）比它的 init 先运行：默认值必须在这里先注册，
        // 否则批量窗口会读到 0 LUFS / 0 dBTP。
        AppSettings.registerDefaults()
        let queue = TaskQueue()
        let analysisQueue = TaskQueue()
        self.queue = queue
        self.analysisQueue = analysisQueue
        self.batch = BatchVolumeController(queue: queue, analysisQueue: analysisQueue)
        self.batchDates = BatchDatesController()
        batchDates.onFileChanged = { [weak self] url in self?.metadataChanged(url) }
        queueObserver = Task { @MainActor [weak self] in
            // 只在任务状态变化时被唤醒，没有轮询。
            for await jobs in await queue.updates() {
                self?.jobs = jobs
            }
        }
        // 检测和试听的进度由音量面板和批量窗口自己显示；结束的任务直接从队列里去掉。
        analysisObserver = Task {
            for await jobs in await analysisQueue.updates() where jobs.contains(where: { $0.status.isFinished }) {
                await analysisQueue.removeFinished()
            }
        }
    }

    // MARK: - 打开 / 关闭

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        closeVideo()
        loadState = .loading(fileName: url.lastPathComponent, message: "正在打开…", jobID: nil)
        let token = UUID()
        openToken = token
        openTask = Task { @MainActor [weak self] in
            await self?.load(url, token: token)
        }
    }

    /// 关闭视频：停止播放，释放播放器、解码器和缩略图缓存，删除预览临时文件。
    func closeVideo() {
        openToken = UUID()
        openTask?.cancel()
        openTask = nil
        if case .loading(_, _, let jobID?) = loadState {
            let queue = self.queue
            Task { await queue.cancel(jobID) }
        }
        volume?.close()
        volume = nil
        if let player {
            player.close()
            if player.playbackURL != player.sourceURL {
                previewStore.remove(player.playbackURL)
            }
        }
        player = nil
        cut = nil
        subtitles = nil
        info = nil
        exportAllOptions = nil
        loadState = .idle
    }

    /// 退出 App 时调用（同步）。
    func prepareForTermination() {
        volume?.close()
        player?.close()
        player = nil
        previewStore.removeSessionDirectory()
    }

    private func load(_ url: URL, token: UUID) async {
        let fileName = url.lastPathComponent
        // 被取消或者已经打开了别的文件。
        func checkCurrent() throws {
            if Task.isCancelled || token != openToken { throw CancellationError() }
        }
        do {
            let inspection = await AssetInspector.inspect(url)
            try checkCurrent()
            if inspection.isPlayable, inspection.hasVideo {
                present(source: url, playback: url, strategy: .native, inspection: inspection)
                return
            }

            // AVPlayer 打不开：用 ffprobe 看编码，决定转封装还是生成代理。
            loadState = .loading(fileName: fileName, message: "正在分析格式…", jobID: nil)
            let info = try await MediaInfo.probe(url)
            try checkCurrent()
            var strategy = try PreviewPlanner.strategy(for: info, nativelyPlayable: false)
            var preview = try await buildPreview(url, info: info, strategy: strategy)
            var previewInspection = await AssetInspector.inspect(preview)
            try checkCurrent()

            // 转封装后 AVPlayer 仍然打不开：改为生成代理。
            if strategy == .remux, !(previewInspection.isPlayable && previewInspection.hasVideo) {
                previewStore.remove(preview)
                strategy = .proxy
                preview = try await buildPreview(url, info: info, strategy: strategy)
                previewInspection = await AssetInspector.inspect(preview)
                try checkCurrent()
            }
            guard previewInspection.isPlayable, previewInspection.hasVideo else {
                previewStore.remove(preview)
                throw PreviewFailure(message: "生成的预览文件无法播放。")
            }
            present(source: url, playback: preview, strategy: strategy, inspection: previewInspection)
        } catch {
            guard token == openToken else { return }  // 已经打开了别的文件，状态由新的任务负责。
            openTask = nil
            fail(fileName, error)
        }
    }

    private func fail(_ fileName: String, _ error: Error) {
        let prefix = "无法打开“\(fileName)”："
        switch error {
        case is CancellationError:
            loadState = .idle
        case let error as ToolError:
            loadState = .failed(message: prefix + (error.errorDescription ?? "未知错误"), log: error.fullLog)
        case let error as PreviewFailure:
            loadState = .failed(message: prefix + error.message, log: error.log)
        default:
            loadState = .failed(message: prefix + error.localizedDescription, log: nil)
        }
    }

    private struct PreviewFailure: Error {
        var message: String
        var log: String? = nil
    }

    /// 在任务队列里生成预览文件，等它完成。取消时删除半成品并抛出 CancellationError。
    private func buildPreview(_ url: URL, info: MediaInfo, strategy: PreviewStrategy) async throws -> URL {
        let output = try previewStore.makePreviewURL(for: url, strategy: strategy)
        let title = strategy == .remux ? "转封装预览：\(url.lastPathComponent)" : "生成预览代理：\(url.lastPathComponent)"
        let builder = PreviewBuilder()
        let id = await queue.enqueue(title: title) { context in
            try await builder.build(source: url, info: info, strategy: strategy, output: output) { progress in
                context.report(progress: progress)
            }
        }
        let message = strategy == .remux
            ? "AVPlayer 不能直接播放这个格式，正在转封装成临时 MP4（不重新编码）…"
            : "AVPlayer 不能播放这个编码，正在生成低分辨率预览（导出时仍然使用原文件）…"
        loadState = .loading(fileName: url.lastPathComponent, message: message, jobID: id)

        let status = await waitForJob(id)
        switch status {
        case .succeeded:
            return output
        case .cancelled:
            previewStore.remove(output)
            throw CancellationError()
        case .failed(let message, let log):
            previewStore.remove(output)
            throw PreviewFailure(message: message, log: log)
        case .queued, .running:
            throw CancellationError()
        }
    }

    /// 等任务结束。任务被取消时（例如关闭视频）也会返回。
    private func waitForJob(_ id: JobID) async -> JobStatus {
        for await jobs in await queue.updates() {
            if let job = jobs.first(where: { $0.id == id }), job.status.isFinished {
                return job.status
            }
        }
        return .cancelled
    }

    func cancelLoading() {
        closeVideo()
    }

    func dismissError() {
        if case .failed = loadState { loadState = .idle }
    }

    private func present(source: URL, playback: URL, strategy: PreviewStrategy, inspection: AssetInspection) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        player = PlayerController(
            sourceURL: source, playbackURL: playback, strategy: strategy,
            inspection: inspection, backingScale: scale)
        cut = CutController(source: source)
        subtitles = SubtitleController(source: source)
        exportAllOptions = ExportAllController()
        let info = InfoController(source: source)
        info.onFileChanged = { [weak self] url, message in self?.metadataChanged(url, result: message) }
        if let pending = pendingInfoResult, pending.url == source { info.showResult(pending.message) }
        pendingInfoResult = nil
        self.info = info
        if let player {
            if let pending = pendingPlayhead, pending.url == source {
                player.movePlayhead(to: pending.time)
            }
            pendingPlayhead = nil
            let volume = VolumeController(
                source: source, duration: player.duration, player: player,
                analysisQueue: analysisQueue, previewStore: previewStore)
            self.volume = volume
            // 打开视频时在后台检测一次响度（有缓存就直接显示）。
            if AppSettings.autoDetectLoudness { volume.detect() }
        }
        loadState = .idle
        openTask = nil
    }

    /// 当前加载任务的进度（0…1），未知时为 nil。
    var loadingProgress: Double? {
        guard case .loading(_, _, let jobID?) = loadState else { return nil }
        return jobs.first { $0.id == jobID }?.progress
    }

    // MARK: - 剪切导出

    /// 把每个区间分别导出成一个新文件（进入任务队列，可以取消）。原文件永远不变。
    func exportCuts(source: URL, ranges: [CutRange], mode: CutMode) {
        for range in ranges {
            let options = AppSettings.cutOptions(mode: mode)
            let title = "剪切 \(source.lastPathComponent)  \(Timecode.format(range.start)) – \(Timecode.format(range.end))（\(mode.displayName)）"
            let exporter = CutExporter()
            let queue = self.queue
            Task { @MainActor [weak self] in
                let id = await queue.enqueue(title: title) { [weak self] context in
                    let model = self
                    let info = try await MediaInfo.probe(source)
                    let plan = try await exporter.plan(source: source, info: info, range: range, options: options)
                    await model?.exportPlanned(id: context.id, output: plan.output, note: plan.leadInMessage)
                    let result = try await exporter.export(plan) { progress in
                        context.report(progress: progress)
                    }
                    if result.output != plan.output {
                        // 规划之后原来的名字被占用了，顺延成了下一个序号。
                        await model?.exportPlanned(id: context.id, output: result.output, note: plan.leadInMessage)
                    }
                }
                guard let self else { return }
                if let index = self.exports.firstIndex(where: { $0.id == id }) {
                    self.exports[index].title = title
                } else {
                    self.exports.append(ExportRecord(id: id, title: title))
                }
            }
        }
    }

    /// 加字幕（视频和音频不重新编码），进任务队列。原文件永远不变。
    func exportSubtitles(_ job: SubtitleJob) {
        var title = "加字幕 \(job.source.lastPathComponent)（\(job.tracks.count) 条，\(job.container.displayName)）"
        if let range = job.range {
            title += "  \(Timecode.format(range.start)) – \(Timecode.format(range.end))"
        }
        let exporter = SubtitleExporter()
        let queue = self.queue
        Task { @MainActor [weak self] in
            let id = await queue.enqueue(title: title) { [weak self] context in
                let model = self
                let info = try await MediaInfo.probe(job.source)
                let result = try await exporter.export(job, info: info) { progress in
                    context.report(progress: progress)
                }
                var note = result.warnings.first
                if let k = result.actualStart, let range = job.range, range.start - k >= 0.0005 {
                    note = String(format: "实际起点提前了 %.3f 秒（从 ", range.start - k) + Timecode.format(k) + " 开始），字幕已按它平移。"
                }
                await model?.exportPlanned(id: context.id, output: result.output, note: note)
            }
            guard let self else { return }
            if !self.exports.contains(where: { $0.id == id }) {
                self.exports.append(ExportRecord(id: id, title: title))
            }
        }
    }

    // MARK: - 音量

    /// 统一音量，写成新文件（进任务队列）。原文件永远不变。
    func exportVolume(_ volume: VolumeController) {
        let job = volume.job()
        let title = "统一音量 \(job.source.lastPathComponent)（\(job.options.preset.displayName)，\(String(format: "%g", job.options.targetLoudness)) LUFS）"
        let queue = self.queue
        Task { @MainActor [weak self, weak volume] in
            let id = await queue.enqueue(title: title) { [weak self, weak volume] context in
                let model = self
                let target = volume
                let result = try await VolumeExporter().export(job) { progress in
                    context.report(progress: progress)
                }
                let note = [result.comparison, result.note].compactMap { $0 }.joined(separator: "\n")
                await model?.exportPlanned(id: context.id, output: result.output, note: note)
                await target?.exportFinished(result)
            }
            guard let self else { return }
            if !self.exports.contains(where: { $0.id == id }) {
                self.exports.append(ExportRecord(id: id, title: title))
            }
        }
    }

    /// 打开批量处理窗口，并把这些视频加入当前页面的列表。
    func addToBatch(_ urls: [URL]) {
        switch batchTab {
        case .volume: batch.add(urls)
        case .dates: batchDates.add(urls)
        }
        pendingBatchWindow = true
    }

    func openBatchWindow(_ tab: BatchTab) {
        batchTab = tab
        pendingBatchWindow = true
    }

    // MARK: - 一次导出

    /// 剪切 → 统一音量 → 加字幕 → 复制元数据，进任务队列。选了“替换原文件”时，完成后原文件移到废纸篓。
    func exportAll(_ job: PipelineJob) {
        var steps: [String] = []
        if let r = job.range { steps.append("剪切 \(Timecode.format(r.start)) – \(Timecode.format(r.end))") }
        if job.volume != nil { steps.append("统一音量") }
        if job.subtitles != nil { steps.append("字幕") }
        let title = "一次导出 \(job.source.lastPathComponent)（\(steps.joined(separator: " + "))）"
        let exporter = PipelineExporter()
        let queue = self.queue
        Task { @MainActor [weak self] in
            let id = await queue.enqueue(title: title) { [weak self] context in
                let model = self
                let result = try await exporter.export(job) { progress in
                    context.report(progress: progress)
                }
                var notes = result.notes
                if result.output == nil { notes.append("没有需要修改的地方，没有生成新文件。") }
                await model?.exportPlanned(id: context.id, output: result.output, note: notes.joined(separator: "\n"))
                if result.replacedOriginal, let output = result.output {
                    await model?.originalReplaced(job.source, by: output)
                }
            }
            guard let self else { return }
            if !self.exports.contains(where: { $0.id == id }) {
                self.exports.append(ExportRecord(id: id, title: title))
            }
        }
    }

    /// 原文件已经移到废纸篓、新文件用了它的名字：正在播放原文件时，改为打开新文件（回到原来的位置）。
    private func originalReplaced(_ original: URL, by newFile: URL) {
        guard let player, player.sourceURL.standardizedFileURL == original.standardizedFileURL else { return }
        pendingPlayhead = (newFile, player.playhead)
        let tab = bottomPanel
        open(newFile)
        bottomPanel = tab
    }

    // MARK: - 信息与日期

    /// 原文件的元数据被修改了。ExifTool / mkvpropedit 是原地修改，播放器手里的采样位置可能已经不对，
    /// 所以正在直接播放这个文件时重新打开（回到原来的播放头位置）。播放的是预览临时文件时不受影响。
    func metadataChanged(_ url: URL, result: String? = nil) {
        guard let player, player.sourceURL.standardizedFileURL == url.standardizedFileURL,
              player.playbackURL == player.sourceURL
        else { return }
        let source = player.sourceURL
        pendingPlayhead = (source, player.playhead)
        if let result { pendingInfoResult = (source, result) }
        let tab = bottomPanel
        open(source)
        bottomPanel = tab
    }

    /// 从 Dock 或 Finder 打开的文件：一个视频直接打开，多个视频放进批量统一音量窗口。
    func openFiles(_ urls: [URL]) {
        _ = handleDrop(urls)
    }

    /// 拖进窗口的文件：字幕文件加进字幕面板；一个视频直接打开；多个视频放进批量统一音量窗口。
    func handleDrop(_ urls: [URL]) -> Bool {
        let subtitleFiles = urls.filter(SubtitleFormat.isSubtitleFile)
        let others = urls.filter { !SubtitleFormat.isSubtitleFile($0) }
        if others.count > 1 {
            addToBatch(others)
            return true
        }
        if let video = others.first {
            open(video)
            return true
        }
        guard !subtitleFiles.isEmpty else { return false }
        guard let subtitles else {
            loadState = .failed(message: "请先打开视频，再把字幕文件拖进来。", log: nil)
            return true
        }
        subtitles.addFiles(subtitleFiles)
        bottomPanel = .subtitles
        return true
    }

    private func exportPlanned(id: JobID, output: URL?, note: String?) {
        if let index = exports.firstIndex(where: { $0.id == id }) {
            exports[index].output = output
            exports[index].note = note
        } else {
            // 任务开始得比记录加进列表还快。
            var record = ExportRecord(id: id, title: output?.lastPathComponent ?? "")
            record.output = output
            record.note = note
            exports.append(record)
        }
    }

    func cancelJob(_ id: JobID) {
        let queue = self.queue
        Task { await queue.cancel(id) }
    }

    /// 去掉已经结束的导出记录。
    func clearFinishedExports() {
        let finished = Set(jobs.filter { $0.status.isFinished }.map(\.id))
        exports.removeAll { finished.contains($0.id) }
        let queue = self.queue
        Task { await queue.removeFinished() }
    }

    func job(_ id: JobID) -> JobSnapshot? {
        jobs.first { $0.id == id }
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 外部工具

    /// 检查外部工具（只在启动时和用户点击“重新检测”时运行一次）。
    func checkTools() async {
        guard !isCheckingTools else { return }
        isCheckingTools = true
        ToolLocator.shared.resetCache()
        tools = await ToolInventory.check()
        isCheckingTools = false
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 一次导出（剪切）。进度和状态从任务队列读。
struct ExportRecord: Identifiable, Equatable {
    let id: JobID
    var title: String
    /// 规划完成后才知道。
    var output: URL?
    /// 例如快速模式的“实际起点会提前 …”。
    var note: String?

    init(id: JobID, title: String) {
        self.id = id
        self.title = title
    }
}

/// 时间轴下面的面板。
enum BottomPanel: String, CaseIterable, Identifiable {
    case cut
    case subtitles
    case volume
    case info
    case exportAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cut: return "剪切"
        case .subtitles: return "字幕"
        case .volume: return "音量"
        case .info: return "信息"
        case .exportAll: return "一次导出"
        }
    }
}
