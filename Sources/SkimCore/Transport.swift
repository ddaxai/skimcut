import Foundation

/// 播放器支持哪些速率（来自 AVPlayerItem 的 canPlayReverse 等属性）。
public struct ShuttleCapabilities: Sendable, Equatable {
    public var reverse: Bool
    public var fastForward: Bool
    public var fastReverse: Bool

    public init(reverse: Bool = true, fastForward: Bool = true, fastReverse: Bool = true) {
        self.reverse = reverse
        self.fastForward = fastForward
        self.fastReverse = fastReverse
    }
}

/// J/K/L 和空格的速率逻辑：
/// - L：正向播放，再按一次加倍（1 → 2 → 4 → 8）；正在倒放时按 L 变成正向 1×；
/// - J：倒放，同样逐次加倍（-1 → -2 → -4 → -8）；
/// - K：暂停；
/// - 空格：暂停时以 1× 播放，播放时暂停。
/// 播放器不支持的速率会被降级（例如不能快进就停在 1×，不能倒放就不动）。
public struct Shuttle: Sendable, Equatable {
    public static let maximumRate: Float = 8

    public private(set) var rate: Float = 0
    public var capabilities: ShuttleCapabilities

    public init(capabilities: ShuttleCapabilities = .init()) {
        self.capabilities = capabilities
    }

    public mutating func pressL() -> Float {
        set(rate <= 0 ? 1 : min(rate * 2, Self.maximumRate))
    }

    public mutating func pressJ() -> Float {
        set(rate >= 0 ? -1 : max(rate * 2, -Self.maximumRate))
    }

    public mutating func pressK() -> Float {
        set(0)
    }

    public mutating func togglePlay() -> Float {
        set(rate == 0 ? 1 : 0)
    }

    /// 播放器自己停下（到了结尾）或被别的操作暂停时同步状态。
    public mutating func sync(rate actual: Float) {
        rate = actual
    }

    private mutating func set(_ wanted: Float) -> Float {
        rate = clamp(wanted)
        return rate
    }

    private func clamp(_ wanted: Float) -> Float {
        if wanted > 1, !capabilities.fastForward { return rate > 0 ? rate : 1 }
        if wanted < 0, !capabilities.reverse { return rate }
        if wanted < -1, !capabilities.fastReverse { return capabilities.reverse ? -1 : rate }
        return wanted
    }
}

/// 有理数时间（对应 CMTime 的 value / timescale），用于精确对齐到帧。
public struct RationalTime: Sendable, Equatable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = max(1, timescale)
    }

    public var seconds: Double { Double(value) / Double(timescale) }
}

/// 逐帧移动用的帧网格：第 n 帧从 n × frameDuration 开始。
public struct FrameGrid: Sendable, Equatable {
    /// 一帧的时长，例如 30000 fps 下的 1001 → 29.97 fps。
    public var frameDuration: RationalTime

    public init(frameDuration: RationalTime) {
        self.frameDuration = frameDuration.value > 0 ? frameDuration : RationalTime(value: 1, timescale: 30)
    }

    /// 从帧率（例如 29.97）构造；无效值按 30 fps。
    public init(framesPerSecond fps: Double) {
        guard fps.isFinite, fps > 0 else {
            self.init(frameDuration: RationalTime(value: 1, timescale: 30))
            return
        }
        // 常见的 NTSC 帧率用精确的 1001 分母。
        for base in [24.0, 30.0, 60.0, 120.0] where abs(fps - base * 1000 / 1001) < 0.005 {
            self.init(frameDuration: RationalTime(value: 1001, timescale: Int32(base * 1000)))
            return
        }
        self.init(frameDuration: RationalTime(value: 1000, timescale: Int32((fps * 1000).rounded())))
    }

    public var secondsPerFrame: Double { frameDuration.seconds }

    /// 时间所在的帧（帧开始时间 ≤ t，容忍 1/4 帧以内的浮点误差）。
    public func frameIndex(at seconds: Double) -> Int64 {
        Int64((seconds / secondsPerFrame + 0.25).rounded(.down))
    }

    /// 视频的最后一帧。
    public func lastFrameIndex(duration: Double) -> Int64 {
        max(0, Int64((duration / secondsPerFrame - 1e-6).rounded(.up)) - 1)
    }

    /// 第 n 帧的开始时间。
    public func time(ofFrame index: Int64) -> RationalTime {
        RationalTime(value: index * frameDuration.value, timescale: frameDuration.timescale)
    }

    /// 从 `seconds` 所在的帧移动 `count` 帧，限制在 0…最后一帧。
    public func step(from seconds: Double, by count: Int64, duration: Double) -> RationalTime {
        let target = min(max(frameIndex(at: seconds) + count, 0), lastFrameIndex(duration: duration))
        return time(ofFrame: target)
    }
}

extension Shuttle {
    /// Shift+←/→ 之类的按秒跳转，限制在 0…duration。
    public static func jump(from seconds: Double, by delta: Double, duration: Double) -> Double {
        min(max(seconds + delta, 0), max(duration, 0))
    }
}
