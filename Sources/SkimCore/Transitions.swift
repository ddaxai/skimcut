import Foundation

/// 转场（拼接处）：硬切或黑屏。
public enum TransitionKind: String, Sendable, Equatable, Hashable {
    /// 画面一下子完全变了。
    case cut
    /// 一段黑屏（包括淡入淡出经过的黑场）。
    case black
}

/// 找到的一个转场。时间都是相对视频开头的秒数。
public struct Transition: Sendable, Equatable, Hashable {
    public var kind: TransitionKind
    /// 前一段内容在这里结束（不含这一帧）：硬切是新画面的第一帧，黑屏是黑屏的第一帧。
    /// “设为结束”用它，剪出来的片段不带黑屏。
    public var outPoint: Double
    /// 后一段内容从这里开始：硬切和 `outPoint` 相同，黑屏是黑屏之后的第一帧。
    /// “设为开始”用它。
    public var inPoint: Double

    public init(kind: TransitionKind, outPoint: Double, inPoint: Double) {
        self.kind = kind
        self.outPoint = outPoint
        self.inPoint = max(inPoint, outPoint)
    }

    public static func cut(at t: Double) -> Transition {
        Transition(kind: .cut, outPoint: t, inPoint: t)
    }

    public static func black(from start: Double, to end: Double) -> Transition {
        Transition(kind: .black, outPoint: start, inPoint: end)
    }

    public var duration: Double { inPoint - outPoint }

    /// 到 `t` 的距离；`t` 在黑屏里面时为 0。
    public func distance(to t: Double) -> Double {
        if t < outPoint { return outPoint - t }
        if t > inPoint { return t - inPoint }
        return 0
    }

    /// 给用户看的说明：“画面切换”“黑屏 0.50 秒”。
    public var displayName: String {
        switch kind {
        case .cut: return "画面切换"
        case .black: return String(format: "黑屏 %.2f 秒", duration)
        }
    }
}

/// 检测参数。
public struct TransitionDetectionOptions: Sendable, Equatable {
    /// 先把画面缩到这么宽再比较（越小越快）。
    public var analysisWidth: Int
    /// `scdet` 的阈值（0…100）：前后两帧差多少算硬切。
    public var sceneThreshold: Double
    /// 黑屏至少多长（秒）。
    public var blackMinDuration: Double
    /// 像素亮度低于多少算黑（0…1）。
    public var blackPixelThreshold: Double
    /// macOS 上用 VideoToolbox 硬件解码（解不了时 ffmpeg 自动改用软件解码）。
    public var hardwareDecode: Bool

    public init(
        analysisWidth: Int = 160, sceneThreshold: Double = 10, blackMinDuration: Double = 0.04,
        blackPixelThreshold: Double = 0.10, hardwareDecode: Bool = TransitionDetectionOptions.defaultHardwareDecode
    ) {
        self.analysisWidth = analysisWidth
        self.sceneThreshold = sceneThreshold
        self.blackMinDuration = blackMinDuration
        self.blackPixelThreshold = blackPixelThreshold
        self.hardwareDecode = hardwareDecode
    }

    public static var defaultHardwareDecode: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// 找全部转场时用稍高的阈值，少一些误判（误判会多切出一段）。
    public static var fullScan: TransitionDetectionOptions {
        TransitionDetectionOptions(sceneThreshold: 14)
    }
}

/// 用 ffmpeg 找转场：画面缩小后，`blackdetect` 找黑屏，`scdet` 找硬切。
///
/// 只解码视频，不输出文件（`-f null -`）。点击时间轴时只分析附近的几秒；
/// “找出全部转场”时分析整段。
public enum TransitionDetector {
    /// 黑屏的边缘和分析范围的边缘离得这么近，说明黑屏可能还没完（被范围截断了）。
    static let edgeTolerance = 0.1
    /// 硬切离黑屏这么近，就是黑屏本身的开始 / 结束，不单独算。
    static let cutNearBlackTolerance = 0.1
    /// 两个硬切离得这么近，算同一个。
    static let duplicateTolerance = 0.02

    /// `scale=W:-2:flags=fast_bilinear,format=gray,blackdetect=…,scdet=…`
    public static func filterGraph(_ options: TransitionDetectionOptions) -> String {
        [
            "scale=\(max(16, options.analysisWidth)):-2:flags=fast_bilinear",
            "format=gray",
            "blackdetect=d=\(format(options.blackMinDuration)):pix_th=\(format(options.blackPixelThreshold))",
            "scdet=threshold=\(format(options.sceneThreshold))",
        ].joined(separator: ",")
    }

    /// `ffmpeg [-hwaccel videotoolbox] [-ss S -t D] -i in -map 0:v:0 -an -sn -dn -vf … -f null -`
    ///
    /// - Parameter window: 只分析这一段（相对视频开头）；nil 表示整段。
    /// - Parameter progress: 是否输出 `-progress pipe:1`（找全部转场时显示进度）。
    public static func arguments(
        input: URL, window: ClosedRange<Double>?, options: TransitionDetectionOptions = .init(), progress: Bool = false
    ) -> [String] {
        var args = ["-hide_banner", "-nostdin"]
        if progress { args += FFmpegProgress.arguments } else { args.append("-nostats") }
        if options.hardwareDecode { args += ["-hwaccel", "videotoolbox"] }
        if let window {
            args += ["-ss", format(window.lowerBound), "-t", format(window.upperBound - window.lowerBound)]
        }
        args += [
            "-i", input.path, "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", filterGraph(options), "-f", "null", "-",
        ]
        return args
    }

    /// 解析 stderr：
    /// `[scdet @ …] lavfi.scd.score: 42.429, lavfi.scd.time: 3`
    /// `[blackdetect @ …] black_start:3 black_end:3.5 black_duration:0.5`
    ///
    /// 用了 `-ss` 时，ffmpeg 输出的时间从 0 开始：加上 `offset` 换算回视频里的时间。
    public static func parse(_ stderr: String, offset: Double = 0) -> [Transition] {
        var cuts: [Double] = []
        var blacks: [(Double, Double)] = []
        stderr.enumerateLines { line, _ in
            if let t = value(after: "lavfi.scd.time:", in: line) {
                cuts.append(t + offset)
            } else if let s = value(after: "black_start:", in: line), let e = value(after: "black_end:", in: line) {
                blacks.append((s + offset, e + offset))
            }
        }
        return combine(cuts: cuts, blacks: blacks)
    }

    /// 合并：重叠的黑屏合成一段；黑屏边上的硬切（就是黑屏的开始 / 结束）去掉；重复的硬切去掉。按时间排序。
    public static func combine(cuts: [Double], blacks: [(Double, Double)]) -> [Transition] {
        var merged: [(Double, Double)] = []
        for (s, e) in blacks.sorted(by: { $0.0 < $1.0 }) where e >= s {
            if let last = merged.last, s <= last.1 + duplicateTolerance {
                merged[merged.count - 1].1 = max(last.1, e)
            } else {
                merged.append((s, e))
            }
        }
        var result = merged.map { Transition.black(from: $0.0, to: $0.1) }
        var kept: [Double] = []
        for t in cuts.sorted() {
            let nearBlack = merged.contains { t >= $0.0 - cutNearBlackTolerance && t <= $0.1 + cutNearBlackTolerance }
            guard !nearBlack else { continue }
            if let last = kept.last, t - last <= duplicateTolerance { continue }
            kept.append(t)
        }
        result += kept.map { Transition.cut(at: $0) }
        return result.sorted { ($0.outPoint, $0.inPoint) < ($1.outPoint, $1.inPoint) }
    }

    /// 分析一段（或整段）。
    ///
    /// 分析一段时：如果有黑屏碰到了这一段的边缘（可能还没完），把那一边往外扩几秒再分析一次（最多两次），
    /// 这样黑屏的开始和结束都是准确的。
    ///
    /// - Returns: 找到的转场，以及实际分析过的范围（用于缓存）。
    public static func detect(
        _ url: URL, window: ClosedRange<Double>?, duration: Double,
        options: TransitionDetectionOptions = .init(),
        runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> (transitions: [Transition], covered: ClosedRange<Double>) {
        guard var range = window else {
            let found = try await run(url, window: nil, duration: duration, options: options, runner: runner, locator: locator, progress: progress)
            return (found, 0...max(duration, 0))
        }
        let extend = 4.0
        var found: [Transition] = []
        for attempt in 0..<3 {
            found = try await run(url, window: range, duration: duration, options: options, runner: runner, locator: locator, progress: nil)
            guard attempt < 2 else { break }
            var lower = range.lowerBound
            var upper = range.upperBound
            for t in found where t.kind == .black {
                if lower > 0, t.outPoint <= lower + edgeTolerance { lower = max(0, lower - extend) }
                if upper < duration, t.inPoint >= upper - edgeTolerance { upper = min(duration, upper + extend) }
            }
            if lower == range.lowerBound, upper == range.upperBound { break }
            range = lower...upper
        }
        // 分析范围的第一帧没有“前一帧”可比，不能发现正好在那里的硬切：缓存时少算一点。
        let coveredLower = range.lowerBound > 0 ? min(range.lowerBound + edgeTolerance, range.upperBound) : 0
        return (found, coveredLower...range.upperBound)
    }

    private static func run(
        _ url: URL, window: ClosedRange<Double>?, duration: Double, options: TransitionDetectionOptions,
        runner: ToolRunner, locator: ToolLocator, progress: (@Sendable (Double?) -> Void)?
    ) async throws -> [Transition] {
        let command = try locator.command(.ffmpeg, arguments(input: url, window: window, options: options, progress: progress != nil))
        let parser = LockedParser()
        let total = window.map { $0.upperBound - $0.lowerBound } ?? duration
        let result = try await runner.run(command, onStdoutLine: { line in
            if let progress, let snapshot = parser.consume(line) {
                progress(snapshot.fraction(totalDuration: total))
            }
        })
        return parse(result.stderrText, offset: window?.lowerBound ?? 0)
    }

    /// `key` 后面的数字（到空白或逗号为止）。
    static func value(after key: String, in line: String) -> Double? {
        guard let r = line.range(of: key) else { return nil }
        let rest = line[r.upperBound...].drop { $0 == " " }
        let token = rest.prefix { !$0.isWhitespace && $0 != "," }
        return Double(token)
    }

    static func format(_ value: Double) -> String {
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// 已经分析过的范围和找到的转场（一个视频一份，关闭视频时丢掉）。
///
/// 点击的位置附近已经分析过时直接用，不再启动 ffmpeg。
public struct TransitionCache: Sendable, Equatable {
    /// 分析过的范围（排好序、互不重叠）。
    public private(set) var covered: [ClosedRange<Double>] = []
    public private(set) var transitions: [Transition] = []

    public init() {}

    /// `range` 是否已经全部分析过。
    public func covers(_ range: ClosedRange<Double>) -> Bool {
        covered.contains { $0.lowerBound <= range.lowerBound + 0.0001 && $0.upperBound >= range.upperBound - 0.0001 }
    }

    /// 整段视频是否已经分析过。
    public func coversWhole(duration: Double) -> Bool {
        covers(0...max(0, duration - 0.05))
    }

    public mutating func insert(_ found: [Transition], covering range: ClosedRange<Double>) {
        var ranges = covered + [range]
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        covered = merged
        let all = transitions + found
        transitions = TransitionDetector.combine(
            cuts: all.filter { $0.kind == .cut }.map(\.outPoint),
            blacks: all.filter { $0.kind == .black }.map { ($0.outPoint, $0.inPoint) })
    }

    public mutating func removeAll() {
        covered = []
        transitions = []
    }
}

/// 点击时间轴后，把播放头吸附到附近的转场。
public enum TransitionSnapper {
    /// 搜索半径：时间轴上 `pixels` 个点对应的时间，至少 `minimum` 秒；`maximum` 为 nil 时不设上限
    /// （已经分析过、不需要解码时）。
    public static func searchRadius(
        secondsPerPixel: Double, pixels: Double = 16, minimum: Double = 0.25, maximum: Double? = 10
    ) -> Double {
        let r = max(secondsPerPixel * pixels, minimum)
        return maximum.map { min(r, $0) } ?? r
    }

    /// 需要分析的范围：搜索范围两边再多分析 `margin` 秒（黑屏的另一边可能在搜索范围外）。
    public static func analysisWindow(
        around t: Double, radius: Double, margin: Double = 1.5, duration: Double
    ) -> ClosedRange<Double> {
        let lower = max(0, t - radius - margin)
        let upper = min(max(duration, 0), t + radius + margin)
        return lower...max(lower, upper)
    }

    /// 离 `t` 最近、并且在 `radius` 以内的转场。
    public static func nearest(to t: Double, in transitions: [Transition], within radius: Double) -> Transition? {
        transitions
            .filter { $0.distance(to: t) <= radius }
            .min { $0.distance(to: t) < $1.distance(to: t) }
    }

    /// 吸附后播放头的位置：
    /// - 硬切：新画面的第一帧；
    /// - 黑屏：离点击位置近的那一边——前一段的最后一帧，或者后一段的第一帧（这样画面上看到的不是黑屏）。
    public static func playheadTime(for transition: Transition, clickedAt t: Double, frameDuration: Double) -> Double {
        switch transition.kind {
        case .cut:
            return transition.inPoint
        case .black:
            let toOut = abs(t - transition.outPoint)
            let toIn = abs(t - transition.inPoint)
            if toOut < toIn, transition.outPoint > 0 {
                return max(0, transition.outPoint - frameDuration)
            }
            return transition.inPoint
        }
    }
}

/// 按转场把整段视频分成几段（每段导出成一个文件）。
public enum TransitionSegments {
    /// 第一段从 0 到第一个转场的 `outPoint`，然后从 `inPoint` 到下一个转场的 `outPoint`……最后一段到结尾。
    /// 黑屏不放进任何一段；短于 `minimumLength` 的段（例如视频开头的黑屏前面）丢掉。
    public static func ranges(duration: Double, transitions: [Transition], minimumLength: Double = 0.5) -> [CutRange] {
        var result: [CutRange] = []
        var start = 0.0
        for t in transitions.sorted(by: { $0.outPoint < $1.outPoint }) {
            let end = min(t.outPoint, duration)
            if end - start >= minimumLength { result.append(CutRange(start: start, end: end)) }
            start = max(start, t.inPoint)
        }
        if duration - start >= minimumLength { result.append(CutRange(start: start, end: duration)) }
        return result
    }
}
