import Foundation

/// 用 ffprobe 找关键帧（快速剪切的实际起点就是起点之前最近的关键帧）。
public enum Keyframes {
    /// 默认往前看 15 秒、一共读 20 秒（AGENTS.md 第 7 节）。
    public static let lookBehind = 15.0
    public static let window = 20.0

    /// `ffprobe -v error -select_streams v:0 -skip_frame nokey -read_intervals "{start-15}%+20"
    ///  -show_entries frame=pts_time -of csv=p=0 in`
    ///
    /// - Parameter around: 相对文件开头的时间（和 ffmpeg `-ss` 一样）。
    /// - Parameter startTime: 容器起始时间；`-read_intervals` 用的是绝对时间。
    public static func arguments(for url: URL, around time: Double, startTime: Double = 0, wholePrefix: Bool = false) -> [String] {
        let interval: String
        if wholePrefix {
            // 从头读到起点之后 1 秒：关键帧间隔特别长时的兜底。
            interval = "%+" + format(time + 1)
        } else {
            interval = format(max(0, max(0, time - lookBehind) + startTime)) + "%+" + format(window)
        }
        return [
            "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
            "-read_intervals", interval,
            "-show_entries", "frame=pts_time", "-of", "csv=p=0", url.path,
        ]
    }

    /// 解析 ffprobe 输出（每行一个时间，可能带逗号；`N/A` 忽略），减去容器起始时间，排序去重。
    public static func parse(_ output: String, startTime: Double = 0) -> [Double] {
        let values = output
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", \t"))) }
            .map { $0 - startTime }
        return Array(Set(values.map { ($0 * 1_000_000).rounded() / 1_000_000 })).sorted()
    }

    /// 不晚于 `time` 的最后一个关键帧（容忍 1 毫秒的误差）。
    public static func keyframe(atOrBefore time: Double, in keyframes: [Double]) -> Double? {
        keyframes.last { $0 <= time + 0.001 }
    }

    /// 找 `time` 之前（含）最近的关键帧。先看附近 20 秒；找不到再从头读。
    /// 视频没有关键帧信息时返回 0（从头开始）。
    public static func keyframe(
        atOrBefore time: Double, in url: URL, startTime: Double = 0,
        runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared
    ) async throws -> Double {
        for wholePrefix in [false, true] {
            let command = try locator.command(
                .ffprobe, arguments(for: url, around: time, startTime: startTime, wholePrefix: wholePrefix))
            let frames = parse(try await runner.output(command), startTime: startTime)
            if let k = keyframe(atOrBefore: time, in: frames) { return max(0, k) }
            if time - lookBehind <= 0 { break }
        }
        return 0
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%.6f", seconds)
    }
}
