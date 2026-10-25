import Foundation

/// 一次导出：剪切 → 统一音量 → 加字幕 → 复制元数据，每一步都可以不做，最后只生成一个文件。
public struct PipelineJob: Sendable, Equatable {
    public struct Subtitles: Sendable, Equatable {
        public var tracks: [SubtitleTrack]
        public var container: SubtitleContainer

        public init(tracks: [SubtitleTrack], container: SubtitleContainer) {
            self.tracks = tracks
            self.container = container
        }
    }

    public var source: URL
    /// 只导出这一段；nil 表示整段（不剪切）。
    public var range: CutRange?
    public var cutMode: CutMode
    /// 统一音量的选项；nil 表示不处理音量。局部压低的时间是原文件里的时间。
    public var volume: NormalizeOptions?
    /// 字幕；nil 表示不处理字幕（剪切时原有字幕不保留，不剪切时原样保留）。
    public var subtitles: Subtitles?
    public var outputDirectory: URL?
    /// 剪出的片段：录制时间 = 原录制时间 + 实际起点。
    public var shiftRecordingDate: Bool
    /// 完成后把原文件移到废纸篓，新文件改用原文件的名字。
    public var replaceOriginal: Bool

    public init(
        source: URL, range: CutRange? = nil, cutMode: CutMode = .precise, volume: NormalizeOptions? = nil,
        subtitles: Subtitles? = nil, outputDirectory: URL? = nil, shiftRecordingDate: Bool = true,
        replaceOriginal: Bool = false
    ) {
        self.source = source
        self.range = range
        self.cutMode = cutMode
        self.volume = volume
        self.subtitles = subtitles
        self.outputDirectory = outputDirectory
        self.shiftRecordingDate = shiftRecordingDate
        self.replaceOriginal = replaceOriginal
    }

    public var hasSteps: Bool { range != nil || volume != nil || subtitles != nil }
}

public struct PipelineResult: Sendable, Equatable {
    /// 最终文件；什么都不需要改时（例如只统一音量而且已经接近目标）为 nil。
    public var output: URL?
    /// 剪切的实际起点（快速模式是起点之前最近的关键帧）。
    public var actualStart: Double?
    public var volume: VolumeResult?
    /// 原文件已经移到废纸篓。
    public var replacedOriginal: Bool
    /// 给用户看的说明（每一步的结果、提示）。
    public var notes: [String]
}

public enum PipelineError: Error, Sendable, Equatable, LocalizedError {
    case nothingToDo
    case trashUnavailable

    public var errorDescription: String? {
        switch self {
        case .nothingToDo: return "没有选择任何步骤（剪切、统一音量、字幕至少选一个）。"
        case .trashUnavailable: return "这个系统不能把文件移到废纸篓，所以不能替换原文件。新文件已经保留。"
        }
    }
}

/// 命名和步骤规划（不运行外部工具，可以单独测试）。
public enum PipelinePlanner {
    /// `原名[_cut_起点-终点][_norm][_subs|_nosubs].扩展名`
    public static func outputFileName(_ job: PipelineJob, extension ext: String) -> String {
        var name = job.source.deletingPathExtension().lastPathComponent
        if let r = job.range { name += "_cut_\(OutputNaming.timeTag(r.start))-\(OutputNaming.timeTag(r.end))" }
        if job.volume != nil { name += "_norm" }
        if let subs = job.subtitles { name += subs.tracks.isEmpty ? "_nosubs" : "_subs" }
        return "\(name).\(ext)"
    }

    /// 剪切之后，局部压低的时间要减去实际起点；不在片段里的去掉。
    public static func shiftDucks(_ ducks: [VolumeDuck], by offset: Double, length: Double) -> [VolumeDuck] {
        ducks.compactMap { d in
            let a = max(d.start - offset, 0)
            let b = min(d.end - offset, length)
            return b > a ? VolumeDuck(start: a, end: b, gain: d.gain) : nil
        }
    }

    /// 替换原文件后的名字：原名 + 新文件的扩展名（扩展名变了时，例如 AVI → MKV，就用新的）。
    public static func replacementURL(original: URL, newFile: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension(newFile.pathExtension)
    }
}

/// 执行一次导出。中间文件放在输出目录里的隐藏文件夹中（和最终文件在同一个卷上），结束后删除。
/// 原文件永远不变，除非选了“替换原文件”（移到废纸篓，不直接删除）。
public struct PipelineExporter: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator
    public var encoder: CutEncoder
    /// 把文件移到废纸篓（测试时可以换成别的）。
    public var trash: @Sendable (URL) throws -> Void

    public init(
        runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared, encoder: CutEncoder = .platformDefault,
        trash: @escaping @Sendable (URL) throws -> Void = PipelineExporter.moveToTrash
    ) {
        self.runner = runner
        self.locator = locator
        self.encoder = encoder
        self.trash = trash
    }

    /// macOS：移到废纸篓。其他系统不支持。
    public static let moveToTrash: @Sendable (URL) throws -> Void = { url in
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        throw PipelineError.trashUnavailable
        #endif
    }

    public func export(_ job: PipelineJob, progress: (@Sendable (Double?) -> Void)? = nil) async throws -> PipelineResult {
        guard job.hasSteps else { throw PipelineError.nothingToDo }
        let fm = FileManager.default
        let info = try await MediaInfo.probe(job.source, runner: runner, locator: locator)
        if let subs = job.subtitles {
            try SubtitlePlanner.validate(
                subs.tracks, container: subs.container, cutting: job.range != nil,
                sourceHasSubtitles: !info.subtitleStreams.isEmpty)
        }
        if job.volume != nil, info.audioStreams.isEmpty { throw LoudnessError.noAudio }

        let directory = job.outputDirectory ?? job.source.deletingLastPathComponent()
        let work = directory.appendingPathComponent(".skimcut-pipeline-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 每一步分到的进度。
        let steps = [job.range != nil, job.volume != nil, job.subtitles != nil].filter { $0 }.count
        var done = 0

        var notes: [String] = []
        var current = job.source
        var actualStart: Double?
        var cutEnd: Double?

        // 1. 剪切（不复制元数据，最后统一复制）。
        if let range = job.range {
            let exporter = CutExporter(runner: runner, locator: locator, encoder: encoder)
            let plan = try await exporter.plan(
                source: job.source, info: info, range: range,
                options: CutOptions(mode: job.cutMode, outputDirectory: work, copyMetadata: false, shiftRecordingDate: false))
            if let lead = plan.leadInMessage { notes.append(lead) }
            notes += plan.warnings
            let d = done
            let result = try await exporter.export(plan) { p in
                if let p { progress?(min((Double(d) + p) / Double(steps), 1) * 0.97) }
            }
            current = result.output
            actualStart = plan.actualStart
            cutEnd = plan.range.end
            done += 1
        }

        // 2. 统一音量（局部压低的时间换算到剪出的片段里）。
        var volumeResult: VolumeResult?
        if var options = job.volume {
            if let start = actualStart, let end = cutEnd {
                options.ducks = PipelinePlanner.shiftDucks(options.ducks, by: start, length: end - start)
            }
            // 原文件的检测结果可以用缓存；中间文件不进缓存。
            let exporter = VolumeExporter(runner: runner, locator: locator, cache: current == job.source ? .shared : nil)
            let d = done
            let result = try await exporter.export(
                VolumeJob(source: current, options: options, outputDirectory: work, copyMetadata: false)
            ) { p in
                if let p { progress?(min((Double(d) + p) / Double(steps), 1) * 0.97) }
            }
            volumeResult = result
            notes.append("音量：" + result.comparison)
            if let note = result.note { notes.append(note) }
            if let output = result.output { current = output }
            done += 1
        }

        // 3. 字幕（原有字幕从原文件取，剪切过时按实际起点平移）。
        var finalExtension = current.pathExtension
        if let subs = job.subtitles {
            finalExtension = subs.container.rawValue
            let output = work.appendingPathComponent("subs.\(subs.container.rawValue)")
            let cut = actualStart.flatMap { start in cutEnd.map { (actualStart: start, end: $0) } }
            let d = done
            try await SubtitleExporter(runner: runner, locator: locator).mux(
                onto: current, original: job.source, originalInfo: info, tracks: subs.tracks,
                container: subs.container, cut: cut, output: output, work: work
            ) { p in
                if let p { progress?(min((Double(d) + p) / Double(steps), 1) * 0.97) }
            }
            notes += SubtitlePlanner.warnings(subs.tracks, container: subs.container)
            current = output
            done += 1
        }

        // 什么都没变（例如只统一音量，而且已经接近目标）：不生成新文件。
        guard current != job.source else {
            progress?(1)
            return PipelineResult(output: nil, actualStart: actualStart, volume: volumeResult, replacedOriginal: false, notes: notes)
        }

        // 4. 复制元数据（MP4/MOV），剪切过时录制时间加上实际起点。
        if MetadataCopier.supports(job.source), MetadataCopier.supports(current) {
            try Task.checkCancellation()
            let shift = job.shiftRecordingDate ? actualStart : nil
            try await MetadataCopier(runner: runner, locator: locator).copy(from: job.source, to: current, shiftDatesBy: shift)
        }

        // 5. 改名成最终文件名（不覆盖），需要时替换原文件。
        try Task.checkCancellation()
        let target = OutputNaming.uniqueURL(directory.appendingPathComponent(
            PipelinePlanner.outputFileName(job, extension: finalExtension)))
        var final = try CutExporter.moveWithoutOverwriting(current, to: target)
        var replaced = false
        if job.replaceOriginal {
            try trash(job.source)
            replaced = true
            let name = PipelinePlanner.replacementURL(original: job.source, newFile: final)
            final = try CutExporter.moveWithoutOverwriting(final, to: name)
            notes.append("原文件已经移到废纸篓。")
        }
        progress?(1)
        return PipelineResult(output: final, actualStart: actualStart, volume: volumeResult, replacedOriginal: replaced, notes: notes)
    }
}
