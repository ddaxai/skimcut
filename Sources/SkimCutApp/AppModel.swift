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
    private(set) var loadState: LoadState = .idle
    /// 任务队列里的全部任务（用于显示进度）。
    private(set) var jobs: [JobSnapshot] = []
    private(set) var tools: [ToolStatus] = []
    private(set) var isCheckingTools = false

    let queue = TaskQueue()
    let previewStore = PreviewFileStore()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    /// 每次打开换一个新值；旧的加载任务发现自己过期后不再修改状态。
    @ObservationIgnored private var openToken = UUID()
    @ObservationIgnored private var queueObserver: Task<Void, Never>?

    init() {
        let queue = self.queue
        queueObserver = Task { @MainActor [weak self] in
            // 只在任务状态变化时被唤醒，没有轮询。
            for await jobs in await queue.updates() {
                self?.jobs = jobs
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
        if let player {
            player.close()
            if player.playbackURL != player.sourceURL {
                previewStore.remove(player.playbackURL)
            }
        }
        player = nil
        loadState = .idle
    }

    /// 退出 App 时调用（同步）。
    func prepareForTermination() {
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
        loadState = .idle
        openTask = nil
    }

    /// 当前加载任务的进度（0…1），未知时为 nil。
    var loadingProgress: Double? {
        guard case .loading(_, _, let jobID?) = loadState else { return nil }
        return jobs.first { $0.id == jobID }?.progress
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
