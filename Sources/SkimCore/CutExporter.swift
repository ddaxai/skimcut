import Foundation

/// 剪切选项。
public struct CutOptions: Sendable, Equatable {
    public var mode: CutMode
    /// 输出目录；nil 表示放在原文件旁边。
    public var outputDirectory: URL?
    /// 从源文件复制元数据（只适用于 MP4/MOV）。
    public var copyMetadata: Bool
    /// 新文件的录制时间 = 原录制时间 + 剪切起点。
    public var shiftRecordingDate: Bool

    public init(mode: CutMode, outputDirectory: URL? = nil, copyMetadata: Bool = true, shiftRecordingDate: Bool = true) {
        self.mode = mode
        self.outputDirectory = outputDirectory
        self.copyMetadata = copyMetadata
        self.shiftRecordingDate = shiftRecordingDate
    }
}

/// 一次剪切的完整计划（导出前就能显示给用户）。
public struct CutPlan: Sendable, Equatable {
    public var source: URL
    public var output: URL
    /// 用户选的区间。
    public var range: CutRange
    public var options: CutOptions
    /// 输出实际开始的时间：精确模式等于起点，快速模式是起点之前最近的关键帧。
    public var actualStart: Double
    public var arguments: [String]
    public var warnings: [String]
    /// 精确模式的编码说明。
    public var encoderDescription: String?
    /// 是否会复制元数据。
    public var copiesMetadata: Bool

    /// 快速模式比要求的起点提前了多少秒。
    public var leadIn: Double { max(0, range.start - actualStart) }

    /// 输出的时长。
    public var outputDuration: Double { range.end - actualStart }

    /// 例如“实际起点会提前 1.833 秒（从 00:01:21.623 开始）”；不提前时为 nil。
    public var leadInMessage: String? {
        guard options.mode == .fast else { return nil }
        guard leadIn >= 0.0005 else { return "起点正好是关键帧，快速模式也是精确的。" }
        return String(format: "实际起点会提前 %.3f 秒", leadIn) + "（从 \(Timecode.format(actualStart)) 开始，那里是最近的关键帧）。"
    }
}

public struct CutResult: Sendable, Equatable {
    public var plan: CutPlan
    public var output: URL { plan.output }
    /// 写入后的录制时间（复制了元数据时）。
    public var recordingDates: RecordingDates?
}

/// 剪切导出：规划（关键帧、文件名、参数）→ 运行 ffmpeg → 复制元数据并核对。
/// 永远不修改原文件；输出不覆盖已有文件；取消或失败时删除没完成的输出。
public struct CutExporter: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator
    public var encoder: CutEncoder

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared, encoder: CutEncoder = .platformDefault) {
        self.runner = runner
        self.locator = locator
        self.encoder = encoder
    }

    public func plan(
        source: URL, info: MediaInfo, range: CutRange, options: CutOptions,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) async throws -> CutPlan {
        guard let video = info.videoStream else { throw CutError.noVideoStream }
        let frame = 1 / max(video.frameRate ?? 30, 1)
        let range = try CutPlanner.validate(range, duration: info.bestDuration, minimumLength: min(frame, 0.04))

        let ext = CutPlanner.outputExtension(for: info, mode: options.mode, sourceExtension: source.pathExtension)
        let directory = options.outputDirectory ?? source.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(
            directory.appendingPathComponent(OutputNaming.cutFileName(source: source, range: range, extension: ext)),
            exists: exists)

        let actualStart: Double
        let arguments: [String]
        switch options.mode {
        case .fast:
            let keyframe = try await Keyframes.keyframe(
                atOrBefore: range.start, in: source, startTime: info.startTime, runner: runner, locator: locator)
            actualStart = CutPlanner.fastActualStart(requested: range.start, keyframeAtOrBefore: keyframe)
            arguments = CutPlanner.fastArguments(input: source, output: output, range: range, info: info)
        case .precise:
            actualStart = range.start
            arguments = try CutPlanner.preciseArguments(
                input: source, output: output, range: range, info: info, encoder: encoder)
        }
        let copies = options.copyMetadata && MetadataCopier.supports(source) && MetadataCopier.supports(output)
        return CutPlan(
            source: source, output: output, range: range, options: options,
            actualStart: actualStart, arguments: arguments,
            warnings: CutPlanner.warnings(for: info, mode: options.mode),
            encoderDescription: options.mode == .precise ? CutPlanner.encoderDescription(for: info, encoder: encoder) : nil,
            copiesMetadata: copies)
    }

    /// 执行计划。`progress` 是 0…1。
    public func export(_ plan: CutPlan, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> CutResult {
        let command = try locator.command(.ffmpeg, plan.arguments)
        let total = plan.outputDuration
        let parser = LockedParser()
        _ = try await runner.run(command, partialOutputs: [plan.output], onStdoutLine: { line in
            if let snapshot = parser.consume(line), let progress {
                // 元数据还没写：最多报到 99%。
                progress(snapshot.fraction(totalDuration: total).map { min($0, 0.99) })
            }
        })

        var dates: RecordingDates?
        if plan.copiesMetadata {
            do {
                try Task.checkCancellation()
                let shift = plan.options.shiftRecordingDate ? plan.actualStart : nil
                dates = try await MetadataCopier(runner: runner, locator: locator)
                    .copy(from: plan.source, to: plan.output, shiftDatesBy: shift)
            } catch {
                // 元数据没写好的文件不算完成。
                try? FileManager.default.removeItem(at: plan.output)
                throw error
            }
        }
        progress?(1)
        return CutResult(plan: plan, recordingDates: dates)
    }
}

/// 在读输出的线程里串行使用，加锁只是为了满足 Sendable。
final class LockedParser: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = FFmpegProgressParser()

    func consume(_ line: String) -> FFmpegProgress? {
        lock.lock()
        defer { lock.unlock() }
        return parser.consume(line: line)
    }
}
