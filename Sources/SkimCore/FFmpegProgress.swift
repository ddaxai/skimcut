import Foundation

/// ffmpeg `-progress pipe:1 -nostats` 输出的一次进度快照。
public struct FFmpegProgress: Sendable, Equatable {
    /// 已处理到的输出时间（秒）。
    public var outTime: Double?
    public var frame: Int?
    /// 处理速度倍数，例如 `2.5x` → 2.5。
    public var speed: Double?
    public var totalSize: Int64?
    /// `progress=end`：ffmpeg 已经处理完。
    public var isEnd: Bool

    public init(outTime: Double? = nil, frame: Int? = nil, speed: Double? = nil, totalSize: Int64? = nil, isEnd: Bool = false) {
        self.outTime = outTime
        self.frame = frame
        self.speed = speed
        self.totalSize = totalSize
        self.isEnd = isEnd
    }

    /// 相对总时长的进度（0…1）；总时长未知时为 nil。
    public func fraction(totalDuration: Double?) -> Double? {
        if isEnd { return 1 }
        guard let total = totalDuration, total > 0, let t = outTime else { return nil }
        return min(max(t / total, 0), 1)
    }

    /// 加在 ffmpeg 参数前面的进度参数。
    public static let arguments = ["-progress", "pipe:1", "-nostats"]
}

/// 逐行解析 `-progress` 输出；每遇到一行 `progress=…` 返回一个快照。
public struct FFmpegProgressParser: Sendable {
    private var current = FFmpegProgress()

    public init() {}

    public mutating func consume(line: String) -> FFmpegProgress? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        switch key {
        case "out_time_us", "out_time_ms":
            // 两个字段的单位其实都是微秒（ffmpeg 的历史遗留）。
            if let us = Int64(value), us >= 0 { current.outTime = Double(us) / 1_000_000 }
        case "out_time":
            if current.outTime == nil, let t = Self.parseClock(value) { current.outTime = t }
        case "frame":
            current.frame = Int(value)
        case "speed":
            current.speed = Double(value.hasSuffix("x") ? String(value.dropLast()) : value)
        case "total_size":
            current.totalSize = Int64(value)
        case "progress":
            var snapshot = current
            snapshot.isEnd = (value == "end")
            current = FFmpegProgress()
            return snapshot
        default:
            break
        }
        return nil
    }

    /// `HH:MM:SS.ffffff` → 秒。
    static func parseClock(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + sec
    }
}
