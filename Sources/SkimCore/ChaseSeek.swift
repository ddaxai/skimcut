import Foundation

/// 一次 seek 请求：目标时间和前后容差（秒）。容差为 0 表示精确 seek。
public struct SeekRequest: Sendable, Equatable {
    public var time: Double
    public var tolerance: Double

    public init(time: Double, tolerance: Double = 0) {
        self.time = time
        self.tolerance = max(0, tolerance)
    }

    public var isExact: Bool { tolerance == 0 }

    /// 已经完成的 `self` 是否已经满足 `other`：同一时间，且容差不比它宽。
    public func satisfies(_ other: SeekRequest) -> Bool {
        abs(time - other.time) < 1e-6 && tolerance <= other.tolerance
    }
}

/// Apple QA1820 的 chase-time 写法（纯状态机，不依赖 AVFoundation）：
///
/// - 没有进行中的 seek 时，立刻发出请求；
/// - 有进行中的 seek 时，只记住最新的目标，不发新的 seek；
/// - 当前 seek 完成后，如果期间有新目标，再发出最新的那一个；
/// - 和上一次完成的 seek 相同（并且容差不更宽）的请求直接忽略。
///
/// 播放器自己移动了位置（播放、逐帧）之后要调用 `invalidate()`。
public struct ChaseSeeker: Sendable {
    public private(set) var inFlight: SeekRequest?
    public private(set) var pending: SeekRequest?
    public private(set) var lastCompleted: SeekRequest?

    public init() {}

    public var isSeeking: Bool { inFlight != nil }

    /// 返回需要立刻发给播放器的 seek；nil 表示不用发（正在 seek 或者已经在那里）。
    public mutating func request(_ request: SeekRequest) -> SeekRequest? {
        if inFlight != nil {
            pending = request
            return nil
        }
        if let last = lastCompleted, last.satisfies(request) {
            return nil
        }
        inFlight = request
        return request
    }

    /// 播放器回调 seek 完成（`finished` 为 false 表示被打断）。返回下一个要发的 seek。
    public mutating func complete(finished: Bool) -> SeekRequest? {
        let done = inFlight
        inFlight = nil
        lastCompleted = finished ? done : nil
        guard let next = pending else { return nil }
        pending = nil
        return request(next)
    }

    /// 播放器位置被别的方式改变了（开始播放、逐帧等），上一次完成的位置不再可信。
    public mutating func invalidate() {
        lastCompleted = nil
    }

    /// 丢掉等待中的目标（例如鼠标离开时间轴，马上要回到播放头）。
    public mutating func dropPending() {
        pending = nil
    }
}
