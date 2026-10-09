import Foundation

/// 时间轴的缩放和滚动：时间 ↔ x 坐标的换算。
///
/// `startTime` 是视图左边缘对应的时间，`pixelsPerSecond` 是缩放比例。
/// 最小缩放是整段视频刚好铺满视图宽度；最大缩放由调用方给出（一般是“一帧一张缩略图”）。
public struct TimelineGeometry: Sendable, Equatable {
    public private(set) var duration: Double
    public private(set) var viewWidth: Double
    public private(set) var pixelsPerSecond: Double
    public private(set) var startTime: Double
    public private(set) var maxPixelsPerSecond: Double

    public init(duration: Double, viewWidth: Double, maxPixelsPerSecond: Double = .infinity) {
        self.duration = max(duration, 0.001)
        self.viewWidth = max(viewWidth, 1)
        self.maxPixelsPerSecond = maxPixelsPerSecond
        self.pixelsPerSecond = 0
        self.startTime = 0
        self.pixelsPerSecond = fitPixelsPerSecond
    }

    /// 整段视频刚好铺满视图时的缩放比例（最小缩放）。
    public var fitPixelsPerSecond: Double { viewWidth / duration }

    /// 实际的最大缩放：不会小于最小缩放。
    public var effectiveMaxPixelsPerSecond: Double { max(maxPixelsPerSecond, fitPixelsPerSecond) }

    /// 每个像素代表的秒数。
    public var secondsPerPixel: Double { 1 / pixelsPerSecond }

    /// 视图里能看到的时间范围。
    public var visibleRange: ClosedRange<Double> {
        startTime...min(duration, startTime + viewWidth / pixelsPerSecond)
    }

    /// 是否已经缩放到整段铺满（不能再缩小）。
    public var isFitted: Bool { pixelsPerSecond <= fitPixelsPerSecond * (1 + 1e-9) }

    public func x(for time: Double) -> Double {
        (time - startTime) * pixelsPerSecond
    }

    /// x 坐标对应的时间，限制在 0…duration。
    public func time(at x: Double) -> Double {
        clampTime(startTime + x / pixelsPerSecond)
    }

    public func clampTime(_ t: Double) -> Double {
        min(max(t, 0), duration)
    }

    /// 以视图里的 `anchorX` 为中心缩放：缩放前后 anchorX 下面的时间不变。
    public mutating func zoom(by factor: Double, anchorX: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let anchorTime = startTime + anchorX / pixelsPerSecond
        pixelsPerSecond = min(max(pixelsPerSecond * factor, fitPixelsPerSecond), effectiveMaxPixelsPerSecond)
        startTime = anchorTime - anchorX / pixelsPerSecond
        clampStart()
    }

    /// 缩放到 1:1（整段铺满）。
    public mutating func zoomToFit() {
        pixelsPerSecond = fitPixelsPerSecond
        startTime = 0
    }

    /// 横向滚动，正数向右（看更晚的时间）。
    public mutating func scroll(byPixels dx: Double) {
        startTime += dx / pixelsPerSecond
        clampStart()
    }

    /// 播放时让 `time` 保持可见：超出右边缘时翻到下一页，跑到左边时让它出现在左侧。
    /// 返回是否滚动了。
    @discardableResult
    public mutating func reveal(_ time: Double, margin: Double = 0) -> Bool {
        let visibleSeconds = viewWidth / pixelsPerSecond
        let marginSeconds = margin / pixelsPerSecond
        let old = startTime
        if time < startTime + marginSeconds {
            startTime = time - marginSeconds
        } else if time > startTime + visibleSeconds - marginSeconds {
            startTime = time - marginSeconds
        }
        clampStart()
        return startTime != old
    }

    /// 视图宽度变化：原来是整段铺满的，继续铺满；否则保持缩放比例和左边缘时间。
    public mutating func resize(viewWidth newWidth: Double) {
        let wasFitted = isFitted
        viewWidth = max(newWidth, 1)
        if wasFitted {
            pixelsPerSecond = fitPixelsPerSecond
        } else {
            pixelsPerSecond = min(max(pixelsPerSecond, fitPixelsPerSecond), effectiveMaxPixelsPerSecond)
        }
        clampStart()
    }

    public mutating func setMaxPixelsPerSecond(_ value: Double) {
        maxPixelsPerSecond = value
        pixelsPerSecond = min(pixelsPerSecond, effectiveMaxPixelsPerSecond)
        clampStart()
    }

    private mutating func clampStart() {
        let visibleSeconds = viewWidth / pixelsPerSecond
        startTime = min(max(startTime, 0), max(0, duration - visibleSeconds))
    }
}

/// 缩略图格子的键：同一缩放级别下的第几个格子。
public struct ThumbnailKey: Hashable, Sendable, CustomStringConvertible {
    /// 格子间隔 = 2^level 秒。
    public let level: Int
    public let index: Int

    public init(level: Int, index: Int) {
        self.level = level
        self.index = index
    }

    public var description: String { "L\(level)#\(index)" }
}

/// 时间轴上的一个缩略图格子。
public struct ThumbnailSlot: Sendable, Equatable {
    public let key: ThumbnailKey
    /// 格子开始的时间（画在这个位置）。
    public let startTime: Double
    /// 格子覆盖的时长。
    public let interval: Double
    /// 向解码器请求的帧时间：格子（在视频范围内那部分）的中间。
    /// 不取格子开头：很多视频第 0 秒是黑的（相机刚开始录、淡入），缩小时第一格会整格变黑。
    public let requestTime: Double
}

/// 缩略图按 2 的幂分级：间隔是 2^level 秒。缩放时同一级别的格子可以复用，
/// 不同缩放比例落在同一级别时不用重新生成。
public enum ThumbnailLadder {
    /// 能放下一张宽 `thumbnailWidth` 像素缩略图的最小级别。
    /// `minimumInterval`（通常是一帧的时长）限制级别下限，不会比一帧更细。
    public static func level(pixelsPerSecond: Double, thumbnailWidth: Double, minimumInterval: Double) -> Int {
        let wanted = max(thumbnailWidth / max(pixelsPerSecond, 1e-9), minimumInterval, 1e-6)
        return Int(log2(wanted).rounded(.up))
    }

    public static func interval(level: Int) -> Double {
        pow(2, Double(level))
    }

    /// 和可见时间范围相交的格子（只生成看得见的部分）。
    public static func slots(level: Int, visible: ClosedRange<Double>, duration: Double) -> [ThumbnailSlot] {
        let interval = interval(level: level)
        guard duration > 0, interval > 0 else { return [] }
        let lastIndex = max(0, Int((duration / interval).rounded(.up)) - 1)
        let first = max(0, Int((visible.lowerBound / interval).rounded(.down)))
        let last = min(lastIndex, Int((visible.upperBound / interval).rounded(.down)))
        guard first <= last else { return [] }
        // 最后一帧附近的时间可能解不出画面，往前留一点。
        let latest = max(0, duration - 0.05)
        return (first...last).map { i in
            let start = Double(i) * interval
            let end = min(start + interval, duration)
            return ThumbnailSlot(
                key: ThumbnailKey(level: level, index: i),
                startTime: start,
                interval: interval,
                requestTime: min((start + end) / 2, latest)
            )
        }
    }
}
