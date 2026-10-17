import Foundation

/// 强度预设。
public enum LoudnessPreset: String, CaseIterable, Sendable, Codable {
    /// 只统一音量：线性增益（`--keep-loudness-range-target`），不改变起伏。
    case unify
    /// 统一 + 拉平：`-lrt 7`。
    case flatten
    /// 强力拉平：前置 `acompressor`，再用 `-lrt 5`。
    case strong

    public var displayName: String {
        switch self {
        case .unify: return "只统一音量"
        case .flatten: return "统一 + 拉平"
        case .strong: return "强力拉平"
        }
    }

    public var explanation: String {
        switch self {
        case .unify: return "整体调大或调小，声音的起伏不变。"
        case .flatten: return "同时把忽大忽小的声音拉近一些（响度范围 7 LU）。"
        case .strong: return "先压缩再统一，大声和小声差别最小（响度范围 5 LU），适合人声忽大忽小的视频。"
        }
    }

    /// 目标响度范围（LU）；nil 表示保持原来的范围。
    public var loudnessRangeTarget: Double? {
        switch self {
        case .unify: return nil
        case .flatten: return 7
        case .strong: return 5
        }
    }
}

/// 局部压低：在 `start…end` 秒把音量降低 `gain` dB（负数）。
public struct VolumeDuck: Sendable, Equatable, Hashable, Codable {
    public var start: Double
    public var end: Double
    public var gain: Double

    public init(start: Double, end: Double, gain: Double) {
        self.start = start
        self.end = end
        self.gain = gain
    }

    /// 默认压低 12 dB。
    public static let defaultGain: Double = -12

    /// 解析 `起点-终点[@dB]`，例如 `10-10.3`、`1:23.4-1:24@-9`。dB 写正数也当作压低。
    public static func parse(_ text: String) -> VolumeDuck? {
        let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let times = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard times.count == 2,
              let a = Timecode.parse(String(times[0]).trimmingCharacters(in: .whitespaces)),
              let b = Timecode.parse(String(times[1]).trimmingCharacters(in: .whitespaces)),
              b > a
        else { return nil }
        var gain = defaultGain
        if parts.count == 2 {
            var g = parts[1].trimmingCharacters(in: .whitespaces)
            if g.lowercased().hasSuffix("db") { g = String(g.dropLast(2)) }
            guard let value = Double(g), value != 0 else { return nil }
            gain = -abs(value)
        }
        return VolumeDuck(start: a, end: b, gain: gain)
    }
}

public struct NormalizeOptions: Sendable, Hashable, Codable {
    /// 目标响度（LUFS）。
    public var targetLoudness: Double
    /// 真峰值上限（dBTP）。
    public var truePeak: Double
    public var preset: LoudnessPreset
    /// 减少喷麦声：`highpass=f=80`。
    public var highpass: Bool
    /// 削波修复：`adeclip`（只能改善，不能完全恢复）。
    public var declip: Bool
    /// 局部压低。
    public var ducks: [VolumeDuck]

    public static let defaultTarget: Double = -16
    public static let defaultTruePeak: Double = -1.5
    /// 已经接近目标（±0.5 LU）的文件跳过。
    public static let threshold: Double = 0.5

    public init(
        targetLoudness: Double = defaultTarget, truePeak: Double = defaultTruePeak, preset: LoudnessPreset = .unify,
        highpass: Bool = false, declip: Bool = false, ducks: [VolumeDuck] = []
    ) {
        self.targetLoudness = targetLoudness
        self.truePeak = truePeak
        self.preset = preset
        self.highpass = highpass
        self.declip = declip
        self.ducks = ducks
    }

    /// 有没有用户明确要求的修复（这时不跳过）。
    public var hasRepairs: Bool { highpass || declip || !ducks.isEmpty || preset == .strong }
}

/// ffmpeg-normalize 的进度：第一遍（逐条音轨测量）和第二遍（写文件）。
public enum NormalizeProgress: Sendable, Equatable {
    case firstPass(stream: Int, of: Int, percent: Double)
    case secondPass(percent: Double)

    /// 整体进度（0…1）：第一遍占一半，第二遍占一半。
    public var fraction: Double {
        switch self {
        case .firstPass(let stream, let count, let percent):
            let n = Double(max(count, 1))
            return min(max((Double(stream - 1) + percent / 100) / n * 0.5, 0), 0.5)
        case .secondPass(let percent):
            return 0.5 + min(max(percent / 100, 0), 1) * 0.5
        }
    }
}

/// ffmpeg-normalize 的参数和滤镜。
public enum NormalizePlanner {
    public static let audioCodecArguments = ["-c:a", "aac", "-b:a", "192k"]
    /// EBU 模式默认会把采样率改成 192 kHz（ffmpeg 6.1 实测是 96 kHz），必须指定。
    public static let sampleRate = "48000"

    // MARK: - 滤镜

    /// 局部压低：`volume=-12.0dB:enable='between(t\,3.000\,3.300)'`。
    /// 表达式里的逗号必须转义成 `\,`，否则会被当成滤镜之间的分隔符（ffmpeg 报 `No such filter`）。
    /// `shift` 秒从时间里减掉（试听片段从 0 开始）；平移后不在 `0…limit` 里的返回 nil。
    public static func duckFilter(_ duck: VolumeDuck, shift: Double = 0, limit: Double? = nil) -> String? {
        let a = max(duck.start - shift, 0)
        let b = duck.end - shift
        guard b > a, b > 0 else { return nil }
        if let limit, a >= limit { return nil }
        return String(format: "volume=%.1fdB:enable='between(t\\,%.3f\\,%.3f)'", duck.gain, a, b)
    }

    /// 强力拉平的压缩：先用线性增益把整体响度调到目标附近（压缩器的阈值是绝对电平），
    /// 再把比目标高 6 dB 以上的部分按 3:1 压缩。没有检测结果时不加增益。
    public static func compressorFilters(target: Double, stats: LoudnessStats?) -> [String] {
        var filters: [String] = []
        if let stats {
            let gain = min(max(target - stats.integrated, -40), 40)
            if abs(gain) >= 0.05 { filters.append(String(format: "volume=%.2fdB", gain)) }
        }
        let threshold = min(max(pow(10, (target - 6) / 20), 0.000977), 1)
        filters.append(String(format: "acompressor=threshold=%.5f:ratio=3:attack=10:release=250", threshold))
        return filters
    }

    /// 写在 loudnorm 前面的滤镜（`-prf`）：削波修复 → 减少喷麦声 → 强力拉平的压缩。
    public static func preFilters(_ options: NormalizeOptions, stats: LoudnessStats?) -> String? {
        var filters: [String] = []
        if options.declip { filters.append("adeclip") }
        if options.highpass { filters.append("highpass=f=80") }
        if options.preset == .strong {
            filters += compressorFilters(target: options.targetLoudness, stats: stats)
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    /// 写在 loudnorm 后面的滤镜（`-pof`）：局部压低。
    /// 放在统一音量之后，才能准确降低设定的 dB：放在前面时，动态模式会把压低的地方又拉回去
    /// （已验证：一段爆音压低 12 dB，放在前面只降了不到 1 dB，放在后面正好 12 dB）。
    /// `shift` 秒从时间里减掉（试听片段从 0 开始）。
    public static func postFilters(_ options: NormalizeOptions, shift: Double = 0, limit: Double? = nil) -> String? {
        let filters = options.ducks.compactMap { duckFilter($0, shift: shift, limit: limit) }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    // MARK: - 跳过

    /// 已经接近目标：整体响度在 ±0.5 LU 以内、真峰值没有超标；“统一 + 拉平”还要求响度范围已经够小。
    /// 选了修复（局部压低、削波修复、减少喷麦声、强力拉平）时不跳过。
    public static func shouldSkip(_ stats: LoudnessStats, options: NormalizeOptions) -> Bool {
        guard !options.hasRepairs else { return false }
        guard abs(stats.integrated - options.targetLoudness) <= NormalizeOptions.threshold,
              stats.truePeak <= options.truePeak + NormalizeOptions.threshold
        else { return false }
        if let lrt = options.preset.loudnessRangeTarget, stats.range > lrt + NormalizeOptions.threshold {
            return false
        }
        return true
    }

    // MARK: - ffmpeg-normalize

    /// `ffmpeg-normalize in -nt ebu -t -16 -tp -1.5 (--keep-loudness-range-target | -lrt 7) -c:a aac -b:a 192k -ar 48000
    ///  [-prf …] [--threshold 0.5] -p -pr -o out`。视频流默认直接复制。
    public static func arguments(input: URL, output: URL, options: NormalizeOptions, stats: LoudnessStats?) -> [String] {
        var args = [input.path, "-nt", "ebu", "-t", number(options.targetLoudness), "-tp", number(options.truePeak)]
        if let lrt = options.preset.loudnessRangeTarget {
            args += ["-lrt", number(lrt)]
        } else {
            args.append("--keep-loudness-range-target")
        }
        args += audioCodecArguments + ["-ar", sampleRate]
        if let pre = preFilters(options, stats: stats) {
            args += ["-prf", pre]
        }
        if let post = postFilters(options) {
            args += ["-pof", post]
        }
        // ffmpeg-normalize 只按整体响度判断是否跳过，所以只在“只统一音量”时交给它。
        if options.preset == .unify, !options.hasRepairs {
            args += ["--threshold", number(NormalizeOptions.threshold)]
        }
        args += ["-p", "-pr", "-o", output.path]
        return args
    }

    /// 输出扩展名：MP4 / M4V / MOV / MKV 保持不变，其他（AVI、FLV、WMV、TS、WebM…）用 MKV。
    public static func outputExtension(for source: URL) -> String {
        let ext = source.pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "mkv"].contains(ext) ? ext : "mkv"
    }

    /// `原名_norm.扩展名`
    public static func outputFileName(source: URL) -> String {
        "\(source.deletingPathExtension().lastPathComponent)_norm.\(outputExtension(for: source))"
    }

    /// 解析 `-pr` 打印的进度（stderr，用 `\r` 分隔）：`Stream 1/2: 45.20% |…`、`Second Pass: 45.20% |…`。
    public static func parseProgress(_ line: String) -> NormalizeProgress? {
        guard let percentEnd = line.range(of: "%") else { return nil }
        let head = line[..<percentEnd.lowerBound]
        guard let colon = head.range(of: ":", options: .backwards),
              let percent = Double(head[colon.upperBound...].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let label = head[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        if label.hasSuffix("Second Pass") {
            return .secondPass(percent: percent)
        }
        if let r = label.range(of: "Stream ", options: .backwards) {
            let parts = label[r.upperBound...].split(separator: "/")
            if parts.count == 2, let i = Int(parts[0]), let n = Int(parts[1]) {
                return .firstPass(stream: i, of: n, percent: percent)
            }
        }
        return nil
    }

    /// `-p` 打印的统计（stdout，JSON 数组）。
    public struct Report: Sendable, Equatable {
        /// ffmpeg-normalize 认为已经接近目标，原样复制了文件。
        public var skipped: Bool
        /// 第二遍实际用的方式：`linear`（线性增益）或 `dynamic`（动态调整）。
        public var normalizationType: String?
    }

    public static func parseReport(_ stdout: String) -> Report {
        guard let start = stdout.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let object = try? JSONSerialization.jsonObject(with: Data(stdout[start...].utf8))
        else { return Report(skipped: false, normalizationType: nil) }
        let entries = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        let skipped = !entries.isEmpty && entries.allSatisfy { ($0["status"] as? String) == "skipped" }
        let type = entries.lazy.compactMap { ($0["ebu_pass2"] as? [String: Any])?["normalization_type"] as? String }.first
        return Report(skipped: skipped, normalizationType: type)
    }

    // MARK: - 和 ffmpeg-normalize 相同的 loudnorm 参数（试听用）

    /// 第一遍：`i=-16.00:lra=7.00:tp=-1.50:offset=0.00`（“只统一音量”第一遍也用默认的 7）。
    public static func firstPassLoudnorm(_ options: NormalizeOptions) -> String {
        String(format: "i=%.2f:lra=%.2f:tp=%.2f:offset=0.00",
               options.targetLoudness, options.preset.loudnessRangeTarget ?? 7, options.truePeak)
    }

    /// 第二遍：带第一遍测到的值，线性模式（达不到时 loudnorm 自己改用动态）。
    public static func secondPassLoudnorm(_ options: NormalizeOptions, measured stats: LoudnessStats) -> String {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        let lra = options.preset.loudnessRangeTarget ?? clamp(stats.range, 1, 50)
        return String(
            format: "i=%.2f:lra=%.2f:tp=%.2f:offset=%.2f:measured_i=%.2f:measured_lra=%.2f:measured_tp=%.2f:measured_thresh=%.2f:linear=true",
            options.targetLoudness, lra, options.truePeak, clamp(stats.targetOffset, -99, 99),
            clamp(stats.integrated, -99, 0), clamp(stats.range, 0, 99), clamp(stats.truePeak, -99, 99),
            clamp(stats.threshold, -99, 0))
    }

    /// 试听片段：从 `start` 开始 `duration` 秒，处理后的声音写成 M4A（只有音频）。
    /// `measured` 是整个文件（加了同样的前置滤镜）的第一遍结果，所以片段的音量和整个文件处理后一致。
    public static func auditionArguments(
        input: URL, start: Double, duration: Double, options: NormalizeOptions,
        stats: LoudnessStats, measured: LoudnessStats, output: URL
    ) -> [String] {
        var filters: [String] = []
        if let pre = preFilters(options, stats: stats) { filters.append(pre) }
        filters.append("loudnorm=" + secondPassLoudnorm(options, measured: measured))
        if let post = postFilters(options, shift: start, limit: duration) { filters.append(post) }
        filters.append("aresample=" + sampleRate)
        return ["-hide_banner", "-nostdin", "-n"] + FFmpegProgress.arguments + [
            "-ss", String(format: "%.3f", start), "-i", input.path, "-t", String(format: "%.3f", duration),
            "-map", "0:a:0", "-vn", "-sn", "-dn", "-af", filters.joined(separator: ","),
        ] + audioCodecArguments + [output.path]
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)
    }
}
