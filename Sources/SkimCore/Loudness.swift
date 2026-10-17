import Foundation

/// 整体响度（EBU R128，来自 ffmpeg `loudnorm` 第一遍的 JSON）。
public struct LoudnessStats: Sendable, Equatable, Codable {
    /// 整体响度 LUFS（`input_i`）。
    public var integrated: Double
    /// 真峰值 dBTP（`input_tp`）。
    public var truePeak: Double
    /// 响度范围 LU（`input_lra`）。
    public var range: Double
    /// 门限（`input_thresh`），第二遍 loudnorm 要用。
    public var threshold: Double
    /// `target_offset`，第二遍 loudnorm 要用。
    public var targetOffset: Double

    public init(integrated: Double, truePeak: Double, range: Double, threshold: Double = -70, targetOffset: Double = 0) {
        self.integrated = integrated
        self.truePeak = truePeak
        self.range = range
        self.threshold = threshold
        self.targetOffset = targetOffset
    }

    /// 例如 `-23.1 LUFS · 真峰值 -3.2 dBTP · 范围 7.4 LU`
    public var summary: String {
        String(format: "%.1f LUFS · 真峰值 %.1f dBTP · 范围 %.1f LU", integrated, truePeak, range)
    }
}

/// 短时响度（`lavfi.r128.M`，每 0.1 秒一个值，窗口 0.4 秒）。
public struct MomentaryLoudness: Sendable, Equatable, Codable {
    /// 每个值对应的时间（秒，窗口的结束时间）。
    public var times: [Float]
    /// LUFS。
    public var values: [Float]

    public init(times: [Float] = [], values: [Float] = []) {
        precondition(times.count == values.count)
        self.times = times
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    /// 低于这个值的点不算（开头窗口没填满时 ffmpeg 输出约 -120）。
    public static let floor: Float = -70
}

/// 一段爆音：短时响度超过“整体响度 + X LU”的区间。
public struct LoudnessBurst: Sendable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    /// 这段里最高的短时响度（LUFS）。
    public var peak: Double

    public init(start: Double, end: Double, peak: Double) {
        self.start = start
        self.end = end
        self.peak = peak
    }

    public var duration: Double { end - start }
}

/// 一次检测的结果（按“路径 + 大小 + 修改时间”缓存）。
public struct LoudnessAnalysis: Sendable, Equatable, Codable {
    public var stats: LoudnessStats
    public var momentary: MomentaryLoudness

    public init(stats: LoudnessStats, momentary: MomentaryLoudness = MomentaryLoudness()) {
        self.stats = stats
        self.momentary = momentary
    }

    /// 超过“整体响度 + margin LU”的区间。
    public func bursts(margin: Double) -> [LoudnessBurst] {
        LoudnessBursts.detect(momentary, integrated: stats.integrated, margin: margin)
    }
}

public enum LoudnessError: Error, Sendable, Equatable, LocalizedError {
    case noAudio
    case silent
    case unparsable

    public var errorDescription: String? {
        switch self {
        case .noAudio: return "这个视频没有音轨。"
        case .silent: return "这个视频的声音是静音的，没法检测和统一音量。"
        case .unparsable: return "无法读取 ffmpeg 的响度检测结果。"
        }
    }
}

/// 爆音检测。
public enum LoudnessBursts {
    /// 默认阈值：比整体响度高 10 LU。
    public static let defaultMargin: Double = 10
    /// 两个超标的点相隔不超过这么多秒时算同一段。
    public static let mergeGap: Double = 0.3
    /// 短时响度的窗口长度：时间 T 的值覆盖 T-0.4 … T。
    public static let window: Double = 0.4

    public static func detect(
        _ momentary: MomentaryLoudness, integrated: Double, margin: Double, mergeGap: Double = mergeGap
    ) -> [LoudnessBurst] {
        let threshold = integrated + margin
        var bursts: [LoudnessBurst] = []
        var first: Double?
        var last = 0.0
        var peak = -Double.infinity
        func close() {
            guard let f = first else { return }
            bursts.append(LoudnessBurst(start: max(0, f - window), end: last, peak: peak))
            first = nil
            peak = -.infinity
        }
        for (t, v) in zip(momentary.times, momentary.values) {
            let value = Double(v)
            guard v > MomentaryLoudness.floor, value > threshold else { continue }
            let time = Double(t)
            if first != nil, time - last > mergeGap + 0.0001 { close() }
            if first == nil { first = time }
            last = time
            peak = max(peak, value)
        }
        close()
        return bursts
    }
}

/// 生成检测命令、解析输出。
public enum LoudnessAnalyzer {
    /// `ffmpeg -nostats -i in -map 0:a:0 -af "[ebur128,ametadata,]loudnorm=print_format=json" -f null -`
    ///
    /// 只解码一遍音频：`ebur128` 和 `ametadata` 原样传递声音，同时把短时响度写进 `momentaryFile`；
    /// `loudnorm` 在 stderr 末尾打印整体响度的 JSON。
    /// - Parameter preFilters: 在测量之前先加的滤镜（试听时用来测“处理后”的响度），可以为空。
    /// - Parameter loudnorm: `loudnorm` 的参数（不含 `print_format`），默认只测量。
    public static func arguments(
        input: URL, momentaryFile: URL?, preFilters: String? = nil, loudnorm: String? = nil
    ) -> [String] {
        var filters: [String] = []
        if let preFilters, !preFilters.isEmpty { filters.append(preFilters) }
        if let momentaryFile {
            filters.append("ebur128=metadata=1")
            filters.append("ametadata=mode=print:key=lavfi.r128.M:file=" + FilterGraph.escapeOptionValue(momentaryFile.path))
        }
        filters.append("loudnorm=" + (loudnorm.map { $0 + ":" } ?? "") + "print_format=json")
        return ["-hide_banner", "-nostdin"] + FFmpegProgress.arguments + [
            "-i", input.path, "-map", "0:a:0", "-vn", "-sn", "-dn",
            "-af", filters.joined(separator: ","), "-f", "null", "-",
        ]
    }

    /// 从 ffmpeg 的 stderr 里取出 loudnorm 打印的最后一个 JSON。
    public static func parseStats(_ stderr: String) throws -> LoudnessStats {
        guard let open = stderr.range(of: "{", options: .backwards),
              let close = stderr.range(of: "}", options: .backwards, range: open.upperBound..<stderr.endIndex)
        else { throw LoudnessError.unparsable }
        let json = stderr[open.lowerBound..<close.upperBound]
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw LoudnessError.unparsable
        }
        func value(_ key: String) -> Double? {
            if let s = object[key] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            return (object[key] as? NSNumber)?.doubleValue
        }
        guard let i = value("input_i"), let tp = value("input_tp"), let lra = value("input_lra") else {
            throw LoudnessError.unparsable
        }
        // 静音时 ffmpeg 输出 "-inf"。
        guard i.isFinite, i > -70, tp.isFinite else { throw LoudnessError.silent }
        let thresh = value("input_thresh").flatMap { $0.isFinite ? $0 : nil } ?? -70
        let offset = value("target_offset").flatMap { $0.isFinite ? $0 : nil } ?? 0
        return LoudnessStats(integrated: i, truePeak: tp, range: lra.isFinite ? lra : 0, threshold: thresh, targetOffset: offset)
    }

    /// 解析 `ametadata=mode=print:file=…` 的输出：
    /// `frame:N    pts:P    pts_time:T` 后面跟一行 `lavfi.r128.M=-23.4`。
    public static func parseMomentary(_ text: String) -> MomentaryLoudness {
        var times: [Float] = []
        var values: [Float] = []
        var time: Float?
        text.enumerateLines { line, _ in
            if let r = line.range(of: "pts_time:") {
                let rest = line[r.upperBound...].prefix { !$0.isWhitespace }
                time = Float(rest)
            } else if let r = line.range(of: "lavfi.r128.M=") {
                if let t = time, let v = Float(line[r.upperBound...].trimmingCharacters(in: .whitespaces)) {
                    times.append(t)
                    values.append(v)
                }
                time = nil
            }
        }
        return MomentaryLoudness(times: times, values: values)
    }

    /// 检测一个文件（第一条音轨）。`includeMomentary` 为 false 时只测整体响度。
    /// `progress` 是 0…1。
    public static func analyze(
        _ url: URL, duration: Double?, includeMomentary: Bool = true, preFilters: String? = nil, loudnorm: String? = nil,
        runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> LoudnessAnalysis {
        let fm = FileManager.default
        var momentaryFile: URL?
        if includeMomentary {
            momentaryFile = fm.temporaryDirectory.appendingPathComponent("skimcut-r128-\(UUID().uuidString).txt")
        }
        defer { if let momentaryFile { try? fm.removeItem(at: momentaryFile) } }

        let command = try locator.command(.ffmpeg, arguments(
            input: url, momentaryFile: momentaryFile, preFilters: preFilters, loudnorm: loudnorm))
        let parser = LockedParser()
        let result: ProcessResult
        do {
            result = try await runner.run(command, partialOutputs: momentaryFile.map { [$0] } ?? [], onStdoutLine: { line in
                if let snapshot = parser.consume(line), let progress {
                    progress(snapshot.fraction(totalDuration: duration))
                }
            })
        } catch ToolError.nonZeroExit(let result) where result.stderrText.contains("matches no streams") {
            throw LoudnessError.noAudio
        }
        let stats = try parseStats(result.stderrText)
        var momentary = MomentaryLoudness()
        if let momentaryFile, let data = fm.contents(atPath: momentaryFile.path) {
            momentary = parseMomentary(String(decoding: data, as: UTF8.self))
        }
        return LoudnessAnalysis(stats: stats, momentary: momentary)
    }
}

/// ffmpeg 滤镜图里的转义。
public enum FilterGraph {
    /// 把任意文字（例如文件路径）放进滤镜的选项值：先按选项层转义 `\ ' :`，
    /// 再按滤镜图层转义 `\ ' , ; [ ]`。整个滤镜图作为一个参数传给 ffmpeg（不经过 shell）。
    public static func escapeOptionValue(_ value: String) -> String {
        escape(escape(value, special: "\\':"), special: "\\',;[]")
    }

    private static func escape(_ s: String, special: String) -> String {
        var out = ""
        for c in s {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
