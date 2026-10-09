import Foundation

/// 时间轴上选中的区间（剪切的起点和终点）。默认是整段视频。
///
/// - 拖动手柄（`moveStart` / `moveEnd`）：限制在另一端之内，至少保留 `minimumLength`；
/// - 按 I / O（`markIn` / `markOut`）：如果新的起点越过了终点（或反过来），另一端回到视频的结尾（开头），
///   和 Final Cut Pro 一样。
public struct TimeSelection: Sendable, Equatable {
    public private(set) var start: Double
    public private(set) var end: Double
    public let duration: Double
    /// 最短长度（通常是一帧）。
    public let minimumLength: Double

    public init(duration: Double, minimumLength: Double) {
        self.duration = max(duration, 0)
        self.minimumLength = min(max(minimumLength, 0), max(duration, 0))
        self.start = 0
        self.end = max(duration, 0)
    }

    public var length: Double { end - start }

    /// 选中的是整段视频（还没有设过起点终点）。
    public var isFull: Bool { start <= 1e-9 && end >= duration - 1e-9 }

    public mutating func reset() {
        start = 0
        end = duration
    }

    /// 拖动起点手柄。
    public mutating func moveStart(to t: Double) {
        start = min(max(t, 0), end - minimumLength)
    }

    /// 拖动终点手柄。
    public mutating func moveEnd(to t: Double) {
        end = max(min(t, duration), start + minimumLength)
    }

    /// I：起点设在这里。越过终点时终点回到结尾。
    public mutating func markIn(at t: Double) {
        let t = min(max(t, 0), duration - minimumLength)
        if t > end - minimumLength { end = duration }
        start = t
    }

    /// O：终点设在这里。在起点之前时起点回到开头。
    public mutating func markOut(at t: Double) {
        let t = max(min(t, duration), minimumLength)
        if t < start + minimumLength { start = 0 }
        end = t
    }
}

/// 选区两端的拖动手柄。
public enum SelectionHandle: Sendable, Equatable {
    case start
    case end

    /// 鼠标 x 是否落在某个手柄上。起点手柄主要向左伸出，终点手柄主要向右伸出；
    /// 两个手柄挨得很近时按鼠标在中点的哪一边决定。
    public static func hitTest(x: Double, startX: Double, endX: Double, tolerance: Double = 8) -> SelectionHandle? {
        let nearStart = x >= startX - tolerance && x <= startX + tolerance / 2
        let nearEnd = x >= endX - tolerance / 2 && x <= endX + tolerance
        switch (nearStart, nearEnd) {
        case (true, true): return x <= (startX + endX) / 2 ? .start : .end
        case (true, false): return .start
        case (false, true): return .end
        case (false, false): return nil
        }
    }
}
