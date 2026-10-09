import Foundation

/// 根据鼠标速度决定 seek 容差：快速划过时用宽容差（解码器可以就近取关键帧，跟得上鼠标），
/// 慢下来或停下时用零容差精确 seek。
public struct SkimTolerancePolicy: Sendable, Equatable {
    /// 超过这个速度（像素/秒）算“快速移动”。
    public var fastSpeed: Double = 300
    /// 容差 ≈ 鼠标在这段时间内划过的时长。
    public var window: Double = 0.1
    public var minimumTolerance: Double = 0.1
    public var maximumTolerance: Double = 2.0

    public init() {}

    public func tolerance(speed: Double, secondsPerPixel: Double) -> Double {
        guard speed >= fastSpeed else { return 0 }
        let covered = speed * secondsPerPixel * window
        return min(max(covered, minimumTolerance), maximumTolerance)
    }
}

/// 鼠标横向速度（像素/秒），做简单的指数平滑。
public struct PointerVelocityTracker: Sendable {
    private var lastX: Double?
    private var lastTime: Double?
    public private(set) var speed: Double = 0
    /// 两次事件间隔超过这个时间（秒），认为鼠标已经停过，速度重新计算。
    public var resetInterval: Double = 0.2

    public init() {}

    @discardableResult
    public mutating func add(x: Double, timestamp: Double) -> Double {
        defer {
            lastX = x
            lastTime = timestamp
        }
        guard let lx = lastX, let lt = lastTime else {
            speed = 0
            return speed
        }
        let dt = timestamp - lt
        guard dt > 0 else { return speed }
        let instant = abs(x - lx) / dt
        speed = dt > resetInterval ? instant : speed * 0.5 + instant * 0.5
        return speed
    }

    public mutating func reset() {
        lastX = nil
        lastTime = nil
        speed = 0
    }
}

/// Skimming 的状态机。不含计时器和播放器：调用方把鼠标事件和定时器到点告诉它，
/// 它返回要执行的动作。
///
/// - 鼠标在时间轴上移动：seek 到对应帧（按速度选容差），并重新安排两个一次性定时器：
///   “停稳”（约 100 ms 后补一次精确 seek）和“停留”（默认 300 ms 后从这里开始播放）；
/// - 停留播放中再移动鼠标：停止播放，回到 skimming；
/// - 鼠标离开：画面回到播放头；
/// - 用户自己在播放（空格 / L）时，悬停不打断播放，只记录 skimmer 位置；
/// - 关闭 skimming 后，悬停什么也不做。
public struct SkimController: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var enabled: Bool
        /// 停留多久开始播放（秒）。
        public var dwell: Double
        /// 停下多久补一次精确 seek（秒）。
        public var settle: Double
        public var tolerance: SkimTolerancePolicy

        public init(enabled: Bool = true, dwell: Double = 0.3, settle: Double = 0.1, tolerance: SkimTolerancePolicy = .init()) {
            self.enabled = enabled
            self.dwell = max(0, dwell)
            self.settle = max(0, settle)
            self.tolerance = tolerance
        }
    }

    public enum State: Sendable, Equatable {
        /// 鼠标不在时间轴上。
        case outside
        /// 正在 skimming（画面显示 skimmer 位置的帧）。
        case skimming
        /// 停留后从 skimmer 位置开始的播放。
        case dwellPlaying
        /// 鼠标在时间轴上，但用户正在正常播放或 skimming 已关闭：不动画面。
        case passive
    }

    public enum TimerKind: Sendable, Equatable {
        case settle
        case dwell
    }

    public enum Action: Sendable, Equatable {
        /// 让画面显示这个时间（经过 chase seek）。
        case seek(SeekRequest)
        /// 取消旧的定时器，按这一代重新安排：`settle` 秒后报告 `.settle`，`dwell` 秒后报告 `.dwell`。
        case scheduleTimers(generation: Int, settle: Double, dwell: Double)
        /// 取消所有定时器。
        case cancelTimers
        /// 从 skimmer 位置开始播放（停留播放）。
        case startDwellPlayback(at: Double)
        /// 停止停留播放。
        case stopDwellPlayback
        /// 画面回到播放头。
        case returnToPlayhead
        /// 播放头移到这里。
        case movePlayhead(to: Double)
    }

    public var configuration: Configuration
    public private(set) var state: State = .outside
    /// skimmer 位置；鼠标不在时间轴上或 skimming 关闭时为 nil。
    public private(set) var skimmerTime: Double?
    private var lastRequest: SeekRequest?
    private var generation = 0
    private var velocity = PointerVelocityTracker()

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// 鼠标在时间轴上移动（进入时也调用这个）。
    /// - Parameters:
    ///   - x: 视图里的横坐标（只用来算速度）。
    ///   - time: 鼠标下面的时间。
    ///   - timestamp: 事件时间（秒，单调递增）。
    ///   - secondsPerPixel: 当前缩放下每个像素的秒数。
    ///   - userIsPlaying: 用户是否在正常播放。
    public mutating func pointerMoved(
        x: Double, time: Double, timestamp: Double, secondsPerPixel: Double, userIsPlaying: Bool
    ) -> [Action] {
        let speed = velocity.add(x: x, timestamp: timestamp)
        guard configuration.enabled else {
            skimmerTime = nil
            state = .passive
            return []
        }
        skimmerTime = time
        if userIsPlaying {
            var actions: [Action] = []
            if state == .skimming || state == .dwellPlaying { actions.append(.cancelTimers) }
            state = .passive
            return actions
        }

        var actions: [Action] = []
        if state == .dwellPlaying { actions.append(.stopDwellPlayback) }
        state = .skimming
        let request = SeekRequest(time: time, tolerance: configuration.tolerance.tolerance(speed: speed, secondsPerPixel: secondsPerPixel))
        lastRequest = request
        actions.append(.seek(request))
        generation += 1
        actions.append(.scheduleTimers(generation: generation, settle: configuration.settle, dwell: configuration.dwell))
        return actions
    }

    /// 一次性定时器到点。过期（不是当前这一代）的定时器忽略。
    public mutating func timerFired(_ kind: TimerKind, generation: Int) -> [Action] {
        guard generation == self.generation, state == .skimming, let last = lastRequest else { return [] }
        switch kind {
        case .settle:
            guard !last.isExact else { return [] }
            let exact = SeekRequest(time: last.time, tolerance: 0)
            lastRequest = exact
            return [.seek(exact)]
        case .dwell:
            state = .dwellPlaying
            lastRequest = SeekRequest(time: last.time, tolerance: 0)
            return [.startDwellPlayback(at: last.time)]
        }
    }

    /// 停留播放时，播放位置就是 skimmer 位置（只用于画 skimmer 线）。
    public mutating func dwellPlaybackAdvanced(to time: Double) {
        if state == .dwellPlaying { skimmerTime = time }
    }

    /// 停留播放到了文件末尾等原因自己停下了。
    public mutating func dwellPlaybackEnded() {
        if state == .dwellPlaying { state = .skimming }
    }

    /// 鼠标离开时间轴。
    public mutating func pointerExited() -> [Action] {
        defer {
            state = .outside
            skimmerTime = nil
            lastRequest = nil
            velocity.reset()
            generation += 1
        }
        switch state {
        case .outside:
            return []
        case .passive:
            return [.cancelTimers]
        case .skimming:
            return [.cancelTimers, .returnToPlayhead]
        case .dwellPlaying:
            return [.cancelTimers, .stopDwellPlayback, .returnToPlayhead]
        }
    }

    /// 点击时间轴：移动播放头。停留播放会停下，画面停在点击的位置。
    public mutating func clicked(at time: Double) -> [Action] {
        var actions: [Action] = []
        if state == .dwellPlaying {
            actions.append(.stopDwellPlayback)
            state = .skimming
        }
        generation += 1
        actions.append(.cancelTimers)
        actions.append(.movePlayhead(to: time))
        if state == .skimming {
            lastRequest = SeekRequest(time: time, tolerance: 0)
        }
        return actions
    }

    /// 用户开始正常播放（空格 / L / J）：停掉 skimming 的定时器。
    public mutating func userPlaybackStarted() -> [Action] {
        guard state == .skimming || state == .dwellPlaying else { return [] }
        state = .passive
        generation += 1
        return [.cancelTimers]
    }

    /// 设置变了（关闭 skimming 时回到播放头）。
    public mutating func updateConfiguration(_ new: Configuration) -> [Action] {
        configuration = new
        guard !new.enabled else { return [] }
        let wasActive = state == .skimming || state == .dwellPlaying
        var actions: [Action] = []
        if state == .dwellPlaying { actions.append(.stopDwellPlayback) }
        if wasActive {
            actions.append(.cancelTimers)
            actions.append(.returnToPlayhead)
        }
        if state != .outside { state = .passive }
        skimmerTime = nil
        generation += 1
        return actions
    }
}
