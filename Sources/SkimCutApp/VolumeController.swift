@preconcurrency import AVFoundation
import Observation
import SkimCore

/// 音量面板的状态：检测结果、爆音标记、处理选项、局部压低、15 秒试听。
///
/// 检测和试听在“分析”队列里运行（一次一个），不会让导出任务排队等着。
/// 试听：画面和原声由主播放器播放，处理后的声音由另一个只放声音的播放器同步播放，
/// “原声 / 处理后”切换只是切换哪一个静音，所以是无缝的。
@MainActor
@Observable
final class VolumeController {
    enum Detection: Equatable {
        /// 还没检测（设置里关了自动检测）。
        case idle
        case detecting(JobID?)
        case ready
        case failed(message: String, log: String?)
    }

    enum Audition: Equatable {
        case idle
        case preparing(JobID?)
        case playing
    }

    /// 原始文件（检测和处理永远用它）。
    let source: URL
    let duration: Double

    private(set) var detection: Detection = .idle
    private(set) var detectionProgress: Double?
    private(set) var analysis: LoudnessAnalysis?
    /// 爆音阈值：比整体响度高这么多 LU。
    var burstMargin: Double {
        didSet { updateMarkers() }
    }
    /// 处理选项（包括局部压低）。
    var options: NormalizeOptions
    /// 新加的局部压低降低多少 dB。
    var duckGain: Double = VolumeDuck.defaultGain

    private(set) var audition: Audition = .idle
    private(set) var auditionProgress: Double?
    private(set) var auditionError: String?
    /// 试听时听处理后的声音（false：原声）。
    var hearsProcessed = true {
        didSet { applyMute() }
    }
    /// 最近一次“生成”的结果（处理前 → 处理后）。
    private(set) var lastResult: VolumeResult?

    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private let analysisQueue: TaskQueue
    @ObservationIgnored private let previewStore: PreviewFileStore
    @ObservationIgnored private var companion: AVPlayer?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var auditionFile: URL?
    @ObservationIgnored private var auditionKey: AuditionKey?
    /// 整个文件加上前置滤镜后的第一遍测量，按选项缓存（改选项后再试听才需要重新测量）。
    @ObservationIgnored private var measured: [NormalizeOptions: LoudnessStats] = [:]

    private struct AuditionKey: Equatable, Sendable {
        var start: Double
        var options: NormalizeOptions
    }

    init(source: URL, duration: Double, player: PlayerController, analysisQueue: TaskQueue, previewStore: PreviewFileStore) {
        self.source = source
        self.duration = duration
        self.player = player
        self.analysisQueue = analysisQueue
        self.previewStore = previewStore
        self.burstMargin = AppSettings.burstMargin
        self.options = AppSettings.defaultNormalizeOptions
    }

    var bursts: [LoudnessBurst] { analysis?.bursts(margin: burstMargin) ?? [] }

    // MARK: - 检测

    /// 检测响度（有缓存时立即完成）。
    func detect() {
        switch detection {
        case .detecting, .ready: return
        case .idle, .failed: break
        }
        if let cached = LoudnessCache.shared.analysis(for: source) {
            detectionSucceeded(cached)
            return
        }
        detection = .detecting(nil)
        detectionProgress = nil
        let source = self.source
        let duration = self.duration
        let queue = analysisQueue
        Task { @MainActor [weak self] in
            let id = await queue.enqueue(title: "检测响度：\(source.lastPathComponent)") { [weak self] context in
                let controller = self
                do {
                    let info = try await MediaInfo.probe(source)
                    guard !info.audioStreams.isEmpty else { throw LoudnessError.noAudio }
                    let analysis = try await VolumeExporter().analyze(source, duration: info.bestDuration ?? duration) { p in
                        context.report(progress: p)
                        Task { @MainActor in controller?.detectionProgress = p }
                    }
                    await controller?.detectionSucceeded(analysis)
                } catch {
                    await controller?.detectionFailed(error)
                    throw error
                }
            }
            guard let self, case .detecting = self.detection else { return }
            self.detection = .detecting(id)
        }
    }

    func cancelDetection() {
        guard case .detecting(let id) = detection else { return }
        detection = .idle
        if let id {
            let queue = analysisQueue
            Task { await queue.cancel(id) }
        }
    }

    private func detectionSucceeded(_ analysis: LoudnessAnalysis) {
        self.analysis = analysis
        detection = .ready
        detectionProgress = nil
        updateMarkers()
    }

    private func detectionFailed(_ error: Error) {
        // 用户点了“取消”时状态已经改回 idle。
        guard case .detecting = detection else { return }
        switch JobStatus.outcome(for: error) {
        case .failed(let message, let log):
            detection = .failed(message: message, log: log)
        default:
            detection = .idle
        }
        detectionProgress = nil
    }

    private func updateMarkers() {
        player?.loudnessMarkers = bursts
    }

    // MARK: - 局部压低

    func isDucked(_ burst: LoudnessBurst) -> Bool {
        options.ducks.contains { abs($0.start - burst.start) < 0.001 && abs($0.end - burst.end) < 0.001 }
    }

    /// 压低 / 不压低这段爆音。
    func toggleDuck(_ burst: LoudnessBurst) {
        if isDucked(burst) {
            options.ducks.removeAll { abs($0.start - burst.start) < 0.001 && abs($0.end - burst.end) < 0.001 }
        } else {
            addDuck(start: burst.start, end: burst.end)
        }
    }

    func addDuck(start: Double, end: Double) {
        guard end > start else { return }
        options.ducks.append(VolumeDuck(start: start, end: end, gain: duckGain))
        options.ducks.sort { $0.start < $1.start }
    }

    func removeDuck(at index: Int) {
        guard options.ducks.indices.contains(index) else { return }
        options.ducks.remove(at: index)
    }

    func setDuckGain(at index: Int, _ gain: Double) {
        guard options.ducks.indices.contains(index) else { return }
        options.ducks[index].gain = gain
    }

    // MARK: - 生成

    func job() -> VolumeJob {
        VolumeJob(source: source, options: options, outputDirectory: AppSettings.outputDirectory)
    }

    func exportFinished(_ result: VolumeResult) {
        lastResult = result
    }

    // MARK: - 试听

    var canAudition: Bool {
        detection == .ready && player != nil
    }

    /// 从 `t` 开始生成（或重用）15 秒处理后的声音，和画面同步播放。
    func startAudition(at t: Double) {
        guard let analysis, player != nil else { return }
        stopAudition(pausePlayer: true)
        auditionError = nil
        let start = min(max(t, 0), max(duration - 1, 0))
        let length = min(VolumeAuditioner.defaultDuration, duration - start)
        let key = AuditionKey(start: start, options: options)
        if let file = auditionFile, auditionKey == key {
            play(file, from: start)
            return
        }
        if let old = auditionFile { previewStore.remove(old) }
        auditionFile = nil
        auditionKey = nil

        let output: URL
        do {
            output = try previewStore.makeTemporaryURL(prefix: "audition", extension: "m4a")
        } catch {
            auditionError = error.localizedDescription
            return
        }
        audition = .preparing(nil)
        auditionProgress = nil
        let source = self.source
        let duration = self.duration
        let options = self.options
        let stats = analysis.stats
        let cachedMeasure = measured[options]
        let queue = analysisQueue
        Task { @MainActor [weak self] in
            let id = await queue.enqueue(title: "试听：\(source.lastPathComponent)") { [weak self] context in
                let controller = self
                do {
                    let auditioner = VolumeAuditioner()
                    let renderShare = cachedMeasure == nil ? 0.2 : 1.0
                    let report: @Sendable (Double?) -> Void = { p in
                        context.report(progress: p)
                        Task { @MainActor in controller?.auditionProgress = p }
                    }
                    var whole = cachedMeasure
                    if whole == nil {
                        let m = try await auditioner.measure(source, options: options, stats: stats, duration: duration) { p in
                            report(p.map { $0 * (1 - renderShare) })
                        }
                        await controller?.storeMeasured(m, for: options)
                        whole = m
                    }
                    try await auditioner.render(
                        source, start: start, duration: length, options: options, stats: stats,
                        measured: whole!, output: output
                    ) { p in
                        report(p.map { (1 - renderShare) + $0 * renderShare })
                    }
                    await controller?.auditionReady(output, key: key)
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    await controller?.auditionFailed(error)
                    throw error
                }
            }
            guard let self, case .preparing = self.audition else { return }
            self.audition = .preparing(id)
        }
    }

    /// 停止试听：停下处理后的声音，取消静音。`pausePlayer` 时画面也停下。
    func stopAudition(pausePlayer: Bool = true) {
        if case .preparing(let id) = audition, let id {
            let queue = analysisQueue
            Task { await queue.cancel(id) }
        }
        player?.onPause = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        companion?.pause()
        companion?.replaceCurrentItem(with: nil)
        companion = nil
        player?.player.isMuted = false
        if pausePlayer, let player, player.mode != .paused { player.pause() }
        audition = .idle
        auditionProgress = nil
    }

    private func storeMeasured(_ stats: LoudnessStats, for options: NormalizeOptions) {
        measured[options] = stats
    }

    private func auditionReady(_ file: URL, key: AuditionKey) {
        guard case .preparing = audition else {
            // 已经停止或关闭：这个文件用不上了。
            previewStore.remove(file)
            return
        }
        auditionFile = file
        auditionKey = key
        play(file, from: key.start)
    }

    private func auditionFailed(_ error: Error) {
        guard case .preparing = audition else { return }
        if case .failed(let message, _) = JobStatus.outcome(for: error) {
            auditionError = "试听生成失败：" + message
        }
        audition = .idle
        auditionProgress = nil
    }

    private func play(_ file: URL, from start: Double) {
        guard let player else { return }
        let item = AVPlayerItem(url: file)
        let companion = AVPlayer(playerItem: item)
        // 用主机时间同步开始时必须关闭。
        companion.automaticallyWaitsToMinimizeStalling = false
        companion.actionAtItemEnd = .pause
        self.companion = companion
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 回调队列是主队列。
            MainActor.assumeIsolated { self.stopAudition(pausePlayer: true) }
        }
        audition = .playing
        applyMute()
        // 用户按空格暂停、或者画面播到结尾：试听一起停下。
        player.onPause = { [weak self] in self?.stopAudition(pausePlayer: false) }
        player.playInSync(from: start, with: companion)
    }

    private func applyMute() {
        guard audition == .playing else { return }
        player?.player.isMuted = hearsProcessed
        companion?.isMuted = !hearsProcessed
    }

    // MARK: - 关闭

    func close() {
        cancelDetection()
        stopAudition(pausePlayer: false)
        if let file = auditionFile { previewStore.remove(file) }
        auditionFile = nil
        player = nil
    }
}
