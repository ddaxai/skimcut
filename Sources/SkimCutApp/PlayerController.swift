@preconcurrency import AVFoundation
import Observation
import SkimCore

/// 一个打开的视频：AVPlayer、播放头、skimming、J/K/L、时间轴缩放。
///
/// 轻量原则：
/// - 暂停时没有计时器：周期时间回调只在播放时注册，停下就移除；
/// - skimming 的“停稳”和“停留”是鼠标移动后才启动的一次性任务；
/// - 所有 seek 经过 chase-time（QA1820），同一时间最多一个 seek 在进行。
@MainActor
@Observable
final class PlayerController {
    enum Mode: Equatable {
        case paused
        /// 用户用空格 / J / L 开始的播放。
        case user
        /// skimming 停留后开始的播放（不移动播放头）。
        case dwell
    }

    /// 用户打开的原始文件（导出时永远用它）。
    let sourceURL: URL
    /// 实际播放的文件：原文件，或者转封装 / 代理生成的临时文件。
    let playbackURL: URL
    let strategy: PreviewStrategy
    let duration: Double
    let frameGrid: FrameGrid
    let aspectRatio: Double

    let player: AVPlayer
    let thumbnails: ThumbnailProvider

    /// 播放头（秒）。
    private(set) var playhead: Double = 0
    /// skimmer 位置；鼠标不在时间轴上时为 nil。
    private(set) var skimmerTime: Double?
    private(set) var mode: Mode = .paused
    private(set) var rate: Float = 0
    /// 时间轴缩放和滚动。
    private(set) var timeline: TimelineGeometry
    /// 选中的区间（剪切的起点和终点，M2 导出时使用）。默认整段。
    private(set) var selection: TimeSelection

    /// 时间轴需要重画时调用（由时间轴视图设置）。
    @ObservationIgnored var redrawTimeline: (() -> Void)?
    /// 让播放画面重新接收键盘（在输入框里按回车之后）。由播放画面设置。
    @ObservationIgnored var focusPlayer: (() -> Void)?

    @ObservationIgnored private var chase = ChaseSeeker()
    @ObservationIgnored private var skim = SkimController()
    @ObservationIgnored private var shuttle = Shuttle()
    /// seek 完成后要设置的播放速率。
    @ObservationIgnored private var pendingRate: Float?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var skimTimerTask: Task<Void, Never>?

    init(sourceURL: URL, playbackURL: URL, strategy: PreviewStrategy, inspection: AssetInspection, backingScale: CGFloat) {
        self.sourceURL = sourceURL
        self.playbackURL = playbackURL
        self.strategy = strategy
        self.duration = max(inspection.duration, 0.001)
        self.frameGrid = inspection.frameGrid
        self.aspectRatio = inspection.aspectRatio

        let item = AVPlayerItem(asset: AVURLAsset(url: playbackURL))
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        // 本地文件：不需要为了网络卡顿而等待缓冲。
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        let thumbnails = ThumbnailProvider(
            url: playbackURL, aspectRatio: inspection.aspectRatio,
            thumbnailHeight: TimelineMetrics.thumbnailHeight, backingScale: backingScale)
        self.thumbnails = thumbnails

        var geometry = TimelineGeometry(
            duration: max(inspection.duration, 0.001), viewWidth: 800, inset: Double(TimelineMetrics.edgeInset))
        // 最大缩放：一帧一张缩略图。
        geometry.setMaxPixelsPerSecond(Double(thumbnails.thumbnailWidth) / inspection.frameGrid.secondsPerFrame)
        self.timeline = geometry
        self.selection = TimeSelection(
            duration: max(inspection.duration, 0.001), minimumLength: inspection.frameGrid.secondsPerFrame)
        skim.configuration = currentSkimConfiguration()
    }

    /// 关闭视频：停止播放、移除回调、释放播放器和缩略图。
    func close() {
        skimTimerTask?.cancel()
        skimTimerTask = nil
        removeTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        thumbnails.close()
        redrawTimeline = nil
        focusPlayer = nil
    }

    var isPlaying: Bool { mode != .paused }

    /// 时间显示用：skimming 时显示 skimmer 位置，否则显示播放头。
    var displayedTime: Double { skimmerTime ?? playhead }

    // MARK: - 键盘

    func perform(_ command: PlaybackCommand) {
        switch command {
        case .togglePlay:
            if mode == .user {
                pause()
            } else {
                startUserPlayback(rate: 1)
            }
        case .shuttleForward:
            updateCapabilities()
            shuttle.sync(rate: mode == .user ? rate : 0)
            applyShuttle(shuttle.pressL())
        case .shuttleReverse:
            updateCapabilities()
            shuttle.sync(rate: mode == .user ? rate : 0)
            applyShuttle(shuttle.pressJ())
        case .shuttleStop:
            pause()
        case .stepForward:
            step(by: 1)
        case .stepBackward:
            step(by: -1)
        case .jumpForward:
            jump(by: AppSettings.jumpSeconds)
        case .jumpBackward:
            jump(by: -AppSettings.jumpSeconds)
        case .zoomIn:
            zoom(by: 2)
        case .zoomOut:
            zoom(by: 0.5)
        case .markIn:
            markIn()
        case .markOut:
            markOut()
        }
    }

    private func applyShuttle(_ newRate: Float) {
        if newRate == 0 {
            pause()
        } else if mode == .user {
            setRate(newRate)
        } else {
            startUserPlayback(rate: newRate)
        }
    }

    // MARK: - 播放

    /// 开始正常播放。如果正在 skimming，从 skimmer 位置开始，播放头也移过去（和 Final Cut Pro 一样）。
    func startUserPlayback(rate newRate: Float) {
        updateCapabilities()
        let skimming = skim.state == .skimming || skim.state == .dwellPlaying
        if mode == .dwell {
            player.pause()
        }
        handle(skim.userPlaybackStarted())
        if skimming, let t = skimmerTime {
            playhead = t
        }
        // 在结尾按播放：从头开始。
        if newRate > 0, playhead >= duration - frameGrid.secondsPerFrame {
            playhead = 0
        }
        mode = .user
        shuttle.sync(rate: newRate)
        installTimeObserver()
        seekThenPlay(time: playhead, rate: newRate)
        redrawTimeline?()
    }

    func pause() {
        let wasPlaying = mode != .paused
        // 还在 seek（刚开始播放就暂停）时，播放器的时间还是旧的，播放头保持 seek 目标。
        let playerTimeIsCurrent = pendingRate == nil && !chase.isSeeking
        player.pause()
        pendingRate = nil
        removeTimeObserver()
        if mode == .user {
            if playerTimeIsCurrent { playhead = clampedPlayerTime() }
        } else if mode == .dwell {
            skim.dwellPlaybackEnded()
        }
        mode = .paused
        rate = 0
        shuttle.sync(rate: 0)
        chase.invalidate()
        if wasPlaying { redrawTimeline?() }
    }

    private func setRate(_ newRate: Float) {
        rate = newRate
        if chase.isSeeking {
            pendingRate = newRate
        } else {
            player.rate = newRate
        }
    }

    private func seekThenPlay(time: Double, rate newRate: Float) {
        rate = newRate
        pendingRate = newRate
        chase.dropPending()
        chase.invalidate()
        if let request = chase.request(SeekRequest(time: time)) {
            issue(request)
        } else if !chase.isSeeking {
            applyPendingRate()
        }
        // 正在 seek：完成时会处理 pendingRate。
    }

    private func applyPendingRate() {
        guard let r = pendingRate else { return }
        pendingRate = nil
        guard mode != .paused else { return }
        player.rate = r
        chase.invalidate()
    }

    private func step(by frames: Int64) {
        if mode != .paused { pause() }
        let target = frameGrid.step(from: playhead, by: frames, duration: duration)
        playhead = target.seconds
        // 目标比帧的开始时间晚一点点，避免浮点误差落到上一帧。
        chaseSeek(SeekRequest(time: target.seconds + 0.0001))
        redrawTimeline?()
    }

    private func jump(by seconds: Double) {
        let target = Shuttle.jump(from: mode == .user ? clampedPlayerTime() : playhead, by: seconds, duration: duration)
        playhead = target
        if mode == .user {
            chase.invalidate()
        } else if mode == .dwell {
            pause()
        }
        chaseSeek(SeekRequest(time: target))
        revealPlayhead()
        redrawTimeline?()
    }

    private func updateCapabilities() {
        guard let item = player.currentItem else { return }
        shuttle.capabilities = ShuttleCapabilities(
            reverse: item.canPlayReverse,
            fastForward: item.canPlayFastForward,
            fastReverse: item.canPlayFastReverse)
    }

    private func clampedPlayerTime() -> Double {
        let t = player.currentTime().seconds
        return t.isFinite ? min(max(t, 0), duration) : playhead
    }

    // MARK: - 周期回调（只在播放时存在）

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            // 回调队列是主队列。
            MainActor.assumeIsolated {
                self.tick(seconds)
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }
    }

    private func tick(_ seconds: Double) {
        // seek 进行中：播放器报告的还是旧时间，不更新位置。
        guard seconds.isFinite, !chase.isSeeking, pendingRate == nil else { return }
        let t = min(max(seconds, 0), duration)
        switch mode {
        case .paused:
            return
        case .user:
            playhead = t
            revealPlayhead()
        case .dwell:
            skim.dwellPlaybackAdvanced(to: t)
            skimmerTime = skim.skimmerTime
        }
        // 到了结尾或开头，播放器自己停下了（周期回调在速率变化时也会触发）。
        if player.rate == 0 {
            pause()
        }
        redrawTimeline?()
    }

    // MARK: - Seek（chase-time）

    private func chaseSeek(_ request: SeekRequest) {
        if let r = chase.request(request) { issue(r) }
    }

    private func issue(_ request: SeekRequest) {
        let time = CMTime(seconds: request.time, preferredTimescale: 90000)
        let tolerance = CMTime(seconds: request.tolerance, preferredTimescale: 90000)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.seekCompleted(finished: finished)
            }
        }
    }

    private func seekCompleted(finished: Bool) {
        if let next = chase.complete(finished: finished) {
            issue(next)
            return
        }
        if !chase.isSeeking { applyPendingRate() }
    }

    // MARK: - 时间轴鼠标

    func pointerMoved(x: Double, timestamp: Double) {
        refreshSkimConfiguration()
        let time = timeline.time(at: x)
        handle(skim.pointerMoved(
            x: x, time: time, timestamp: timestamp,
            secondsPerPixel: timeline.secondsPerPixel, userIsPlaying: mode == .user))
        skimmerTime = skim.skimmerTime
        redrawTimeline?()
    }

    func pointerExited() {
        handle(skim.pointerExited())
        skimmerTime = nil
        redrawTimeline?()
    }

    func clicked(x: Double) {
        refreshSkimConfiguration()
        handle(skim.clicked(at: timeline.time(at: x)))
        skimmerTime = skim.skimmerTime
        redrawTimeline?()
    }

    private func handle(_ actions: [SkimController.Action]) {
        for action in actions {
            switch action {
            case .seek(let request):
                chaseSeek(request)
            case .scheduleTimers(let generation, let settle, let dwell):
                scheduleSkimTimers(generation: generation, settle: settle, dwell: dwell)
            case .cancelTimers:
                skimTimerTask?.cancel()
                skimTimerTask = nil
            case .startDwellPlayback(let t):
                mode = .dwell
                installTimeObserver()
                seekThenPlay(time: t, rate: 1)
            case .stopDwellPlayback:
                player.pause()
                pendingRate = nil
                removeTimeObserver()
                mode = .paused
                rate = 0
                chase.invalidate()
            case .returnToPlayhead:
                chase.dropPending()
                chaseSeek(SeekRequest(time: playhead))
            case .movePlayhead(let t):
                playhead = t
                if mode == .user { chase.invalidate() }
                chaseSeek(SeekRequest(time: t))
            }
        }
    }

    private func scheduleSkimTimers(generation: Int, settle: Double, dwell: Double) {
        skimTimerTask?.cancel()
        skimTimerTask = Task { @MainActor [weak self] in
            let first = min(settle, dwell)
            try? await Task.sleep(nanoseconds: UInt64(first * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.skimTimerFired(.settle, generation: generation)
            try? await Task.sleep(nanoseconds: UInt64(max(0, dwell - first) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.skimTimerFired(.dwell, generation: generation)
        }
    }

    private func skimTimerFired(_ kind: SkimController.TimerKind, generation: Int) {
        handle(skim.timerFired(kind, generation: generation))
        if kind == .dwell { skimTimerTask = nil }
    }

    private func currentSkimConfiguration() -> SkimController.Configuration {
        SkimController.Configuration(enabled: AppSettings.skimmingEnabled, dwell: AppSettings.skimDwell)
    }

    /// 设置可能在设置窗口里改了：每次鼠标事件时同步（UserDefaults 读取很便宜）。
    private func refreshSkimConfiguration() {
        let config = currentSkimConfiguration()
        if config != skim.configuration {
            handle(skim.updateConfiguration(config))
        }
    }

    // MARK: - 选区（起点 / 终点）

    /// I：起点设在当前显示的那一帧的开头（skimming 时是 skimmer 位置，否则是播放头）。
    func markIn() {
        let index = frameGrid.frameIndex(at: displayedTime)
        selection.markIn(at: frameGrid.time(ofFrame: index).seconds)
        redrawTimeline?()
    }

    /// O：终点设在当前显示的那一帧的结尾（包含这一帧）。
    func markOut() {
        let index = frameGrid.frameIndex(at: displayedTime)
        selection.markOut(at: min(frameGrid.time(ofFrame: index + 1).seconds, duration))
        redrawTimeline?()
    }

    /// 输入框设置起点：对齐到这个时间所在那一帧的开头。
    func setSelectionStart(_ t: Double) {
        let index = frameGrid.frameIndex(at: min(max(t, 0), duration))
        selection.markIn(at: frameGrid.time(ofFrame: index).seconds)
        redrawTimeline?()
    }

    /// 输入框设置终点：对齐到最近的帧边界。
    func setSelectionEnd(_ t: Double) {
        let boundary = frameGrid.time(ofFrame: Int64((max(t, 0) / frameGrid.secondsPerFrame).rounded())).seconds
        selection.markOut(at: min(boundary, duration))
        redrawTimeline?()
    }

    /// 当前选区（导出用）。
    var selectedRange: CutRange { CutRange(start: selection.start, end: selection.end) }

    /// 把选区设成列表里保存的某个区间（点击列表时预览）。
    func select(_ range: CutRange) {
        selection.reset()
        selection.moveEnd(to: range.end)
        selection.moveStart(to: range.start)
        playhead = range.start
        if mode != .paused { pause() }
        chaseSeek(SeekRequest(time: range.start + 0.0001))
        timeline.reveal(range.start)
        redrawTimeline?()
    }

    func resetSelection() {
        selection.reset()
        redrawTimeline?()
    }

    /// 开始拖动选区手柄：停止播放和 skimming 的定时器，画面跟着手柄走。
    func beginHandleDrag() {
        if mode == .user { pause() }
        handle(skim.suspend())
        skimmerTime = nil
    }

    /// 拖动手柄到 x：吸附到最近的帧边界，画面显示选区里紧挨着手柄的那一帧。
    func dragHandle(_ handle: SelectionHandle, x: Double) {
        let raw = timeline.time(at: x)
        let boundary = min(frameGrid.time(ofFrame: Int64((raw / frameGrid.secondsPerFrame).rounded())).seconds, duration)
        let shown: Double
        switch handle {
        case .start:
            selection.moveStart(to: boundary)
            shown = selection.start
        case .end:
            selection.moveEnd(to: boundary)
            // 终点是区间的结尾，显示它前面的最后一帧。
            shown = max(selection.start, selection.end - frameGrid.secondsPerFrame)
        }
        chaseSeek(SeekRequest(time: shown + 0.0001))
        redrawTimeline?()
    }

    func endHandleDrag() {
        redrawTimeline?()
    }

    // MARK: - 缩放

    func zoom(by factor: Double, anchorX: Double? = nil) {
        let anchor: Double
        if let anchorX {
            anchor = anchorX
        } else {
            // 播放头在可见范围内时以它为中心，否则以视图中心。
            let x = timeline.x(for: playhead)
            anchor = (0...timeline.viewWidth).contains(x) ? x : timeline.viewWidth / 2
        }
        timeline.zoom(by: factor, anchorX: anchor)
        redrawTimeline?()
    }

    func zoomToFit() {
        timeline.zoomToFit()
        redrawTimeline?()
    }

    func scrollTimeline(byPixels dx: Double) {
        timeline.scroll(byPixels: dx)
        redrawTimeline?()
    }

    func resizeTimeline(width: Double) {
        guard abs(width - timeline.viewWidth) > 0.5 else { return }
        timeline.resize(viewWidth: width)
        redrawTimeline?()
    }

    private func revealPlayhead() {
        timeline.reveal(playhead)
    }
}

/// 时间轴的尺寸（点）。
enum TimelineMetrics {
    /// 时间轴左右两端的空白：视频开头和结尾的手柄在这里，鼠标也更容易停到第一帧和最后一帧。
    static let edgeInset: CGFloat = 10
    /// 选区手柄的宽度（放在空白里，正好能抓住）。
    static let handleWidth: CGFloat = 7
    static let rulerHeight: CGFloat = 18
    static let thumbnailHeight: CGFloat = 56
    static let padding: CGFloat = 4
    static var totalHeight: CGFloat { rulerHeight + thumbnailHeight + padding * 2 }
}
