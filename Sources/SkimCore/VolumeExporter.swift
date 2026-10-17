import Foundation

/// 一次统一音量的请求。
public struct VolumeJob: Sendable, Equatable {
    public var source: URL
    public var options: NormalizeOptions
    /// 输出目录；nil 表示放在原文件旁边。
    public var outputDirectory: URL?
    /// 从源文件复制元数据（只适用于 MP4/MOV）。
    public var copyMetadata: Bool

    public init(source: URL, options: NormalizeOptions = NormalizeOptions(), outputDirectory: URL? = nil, copyMetadata: Bool = true) {
        self.source = source
        self.options = options
        self.outputDirectory = outputDirectory
        self.copyMetadata = copyMetadata
    }
}

public struct VolumeResult: Sendable, Equatable {
    public var source: URL
    /// 新文件；已经接近目标、跳过时为 nil（不生成新文件）。
    public var output: URL?
    /// 处理前。
    public var before: LoudnessStats
    /// 处理后重新检测的结果；跳过时为 nil。
    public var after: LoudnessStats?
    /// 第二遍用的方式：`linear` / `dynamic`。
    public var normalizationType: String?
    /// 需要告诉用户的情况，例如“只统一音量”实际改成了动态调整。
    public var note: String?

    public var skipped: Bool { output == nil }

    /// 例如“-31.2 → -16.0 LUFS，真峰值 -12.0 → -2.1 dBTP，范围 6.1 → 6.0 LU”。
    public var comparison: String {
        guard let after else {
            return String(format: "已接近目标（%.1f LUFS），跳过，没有生成新文件。", before.integrated)
        }
        return String(
            format: "%.1f → %.1f LUFS，真峰值 %.1f → %.1f dBTP，范围 %.1f → %.1f LU",
            before.integrated, after.integrated, before.truePeak, after.truePeak, before.range, after.range)
    }
}

/// 统一音量：检测（有缓存就不再检测）→ ffmpeg-normalize（视频直接复制，只重新编码音频）
/// → 复制元数据 → 重新检测 → 改名成 `原名_norm.扩展名`。
///
/// 永远不修改原文件；输出不覆盖已有文件；取消或失败时删除没完成的输出和 ffmpeg-normalize 的临时目录。
public struct VolumeExporter: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator
    public var cache: LoudnessCache?

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared, cache: LoudnessCache? = .shared) {
        self.runner = runner
        self.locator = locator
        self.cache = cache
    }

    /// 检测（结果按“路径 + 大小 + 修改时间”缓存）。
    public func analyze(
        _ url: URL, duration: Double?, progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> LoudnessAnalysis {
        if let cached = cache?.analysis(for: url) { return cached }
        let analysis = try await LoudnessAnalyzer.analyze(
            url, duration: duration, runner: runner, locator: locator, progress: progress)
        cache?.store(analysis, for: url)
        return analysis
    }

    public func export(
        _ job: VolumeJob, info: MediaInfo? = nil, progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> VolumeResult {
        var probed = info
        if probed == nil { probed = try await MediaInfo.probe(job.source, runner: runner, locator: locator) }
        let info = probed!
        guard !info.audioStreams.isEmpty else { throw LoudnessError.noAudio }
        let duration = info.bestDuration

        // 1. 处理前的数值（打开视频时通常已经检测过，直接用缓存）。
        let cached = cache?.analysis(for: job.source) != nil
        let detectShare = cached ? 0 : 0.15
        let before = try await analyze(job.source, duration: duration) { p in
            progress?(p.map { $0 * detectShare })
        }.stats
        if NormalizePlanner.shouldSkip(before, options: job.options) {
            progress?(1)
            return VolumeResult(source: job.source, output: nil, before: before, after: nil)
        }

        // 2. ffmpeg-normalize 写进同一目录的隐藏临时文件；它自己的临时文件放在单独的目录里，结束后删除。
        let directory = job.outputDirectory ?? job.source.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(directory.appendingPathComponent(NormalizePlanner.outputFileName(source: job.source)))
        let temp = CutExporter.temporaryURL(for: output)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skimcut-normalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var command = try locator.command(.ffmpegNormalize, NormalizePlanner.arguments(
            input: job.source, output: temp, options: job.options, stats: before))
        command.environment["TMPDIR"] = workDir.path
        let normalizeShare = 0.85 - detectShare
        let result = try await runner.run(command, partialOutputs: [temp, workDir], onStderrLine: { line in
            if let p = NormalizePlanner.parseProgress(line) {
                progress?(detectShare + p.fraction * normalizeShare)
            }
        })
        let report = NormalizePlanner.parseReport(result.stdoutText)
        if report.skipped {
            // ffmpeg-normalize 把已经接近目标的文件原样复制了一份：这样的副本没有用。
            try? FileManager.default.removeItem(at: temp)
            progress?(1)
            return VolumeResult(source: job.source, output: nil, before: before, after: nil)
        }

        do {
            // 3. 元数据、重新检测都在临时文件上做，全部成功才改名。
            if job.copyMetadata, MetadataCopier.supports(job.source), MetadataCopier.supports(temp) {
                try Task.checkCancellation()
                try await MetadataCopier(runner: runner, locator: locator).copy(from: job.source, to: temp, shiftDatesBy: nil)
            }
            try Task.checkCancellation()
            let after = try await LoudnessAnalyzer.analyze(temp, duration: duration, runner: runner, locator: locator) { p in
                progress?(0.85 + (p ?? 0) * 0.15)
            }
            try Task.checkCancellation()
            let final = try CutExporter.moveWithoutOverwriting(temp, to: output)
            cache?.store(after, for: final)
            progress?(1)
            var note: String?
            if job.options.preset == .unify, report.normalizationType == "dynamic" {
                note = "声音的峰值太高，只整体调大会超过真峰值上限，所以 ffmpeg 自动改成了动态调整（声音的起伏会变小一些）。"
            }
            return VolumeResult(
                source: job.source, output: final, before: before, after: after.stats,
                normalizationType: report.normalizationType, note: note)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

/// 试听：从某个位置生成一段处理后的声音（M4A），和原声对比。
public struct VolumeAuditioner: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator

    /// 试听片段的长度（秒）。
    public static let defaultDuration: Double = 15

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared) {
        self.runner = runner
        self.locator = locator
    }

    /// 整个文件加上前置滤镜后的第一遍测量（和 ffmpeg-normalize 的第一遍相同）。结果可以按选项缓存。
    public func measure(
        _ source: URL, options: NormalizeOptions, stats: LoudnessStats, duration: Double?,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> LoudnessStats {
        try await LoudnessAnalyzer.analyze(
            source, duration: duration, includeMomentary: false,
            preFilters: NormalizePlanner.preFilters(options, stats: stats),
            loudnorm: NormalizePlanner.firstPassLoudnorm(options),
            runner: runner, locator: locator, progress: progress
        ).stats
    }

    /// 生成试听片段。失败或取消时删除半成品。
    public func render(
        _ source: URL, start: Double, duration: Double = defaultDuration, options: NormalizeOptions,
        stats: LoudnessStats, measured: LoudnessStats, output: URL,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        let args = NormalizePlanner.auditionArguments(
            input: source, start: start, duration: duration, options: options,
            stats: stats, measured: measured, output: output)
        let parser = LockedParser()
        _ = try await runner.run(try locator.command(.ffmpeg, args), partialOutputs: [output], onStdoutLine: { line in
            if let snapshot = parser.consume(line), let progress {
                progress(snapshot.fraction(totalDuration: duration))
            }
        })
    }
}
