import Foundation

/// 一条要写进输出文件的字幕轨道。
public struct SubtitleTrack: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        /// 拖进来的字幕文件。
        case file(URL)
        /// 源视频里已有的字幕流（ffprobe 的流序号）。
        case embedded(streamIndex: Int)
    }

    public let id: UUID
    public var source: Source
    public var format: SubtitleFormat
    /// ISO 639-2，默认 `chi`。
    public var language: String
    public var title: String
    public var isDefault: Bool
    /// 文字字幕检测出来的编码（uchardet）；nil 表示还没检测或不需要。
    public var charset: String?

    public init(
        id: UUID = UUID(), source: Source, format: SubtitleFormat,
        language: String = SubtitleLanguages.defaultCode, title: String = "", isDefault: Bool = false, charset: String? = nil
    ) {
        self.id = id
        self.source = source
        self.format = format
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.charset = charset
    }

    /// 源视频里已有的字幕流 → 轨道（默认保留原来的语言、标题和默认标记）。
    public static func embedded(_ stream: MediaStream) -> SubtitleTrack? {
        guard stream.isSubtitle, let format = SubtitleFormat.fromCodec(stream.codecName) else { return nil }
        let lang = stream.language.map(SubtitleLanguages.normalize) ?? "und"
        return SubtitleTrack(
            source: .embedded(streamIndex: stream.index), format: format,
            language: lang, title: stream.title ?? "", isDefault: stream.isDefault)
    }

    public var isEmbedded: Bool {
        if case .embedded = source { return true }
        return false
    }
}

public enum SubtitleError: Error, Sendable, Equatable, LocalizedError {
    case noTracks
    case bitmapNeedsMKV
    case bitmapCannotBeCut
    case unknownEncoding(String)

    public var errorDescription: String? {
        switch self {
        case .noTracks:
            return "没有要写入的字幕轨道。"
        case .bitmapNeedsMKV:
            return "图形字幕（SUP、IDX/SUB、DVB）只能输出为 MKV。"
        case .bitmapCannotBeCut:
            return "图形字幕（SUP、IDX/SUB）的时间不能平移，不能和“只导出当前选区”一起使用。"
        case .unknownEncoding(let name):
            return "无法识别字幕文件“\(name)”的文字编码，请先把它转成 UTF-8。"
        }
    }
}

/// 字幕封装的规划：容器、每条轨道的编码方式和完整的 ffmpeg 参数（数组，不经过 shell）。
public enum SubtitlePlanner {
    /// 可以选的输出容器：有图形字幕时只有 MKV。
    public static func allowedContainers(_ tracks: [SubtitleTrack]) -> [SubtitleContainer] {
        tracks.allSatisfy(\.format.isText) ? [.mp4, .mkv] : [.mkv]
    }

    /// 导出前给用户的提示。
    public static func warnings(_ tracks: [SubtitleTrack], container: SubtitleContainer) -> [String] {
        var w: [String] = []
        if container == .mp4, tracks.contains(where: \.format.hasStyles) {
            w.append("MP4 的字幕不支持样式：ASS/SSA 的字体、颜色、位置会丢失，只保留文字。需要保留样式请选 MKV。")
        }
        return w
    }

    /// 每条字幕在输出里的编码：MP4 全部转成 mov_text；MKV 原样复制（mov_text 不能放进 MKV，转成 SRT）。
    public static func outputCodec(for format: SubtitleFormat, container: SubtitleContainer) -> String {
        switch container {
        case .mp4: return "mov_text"
        case .mkv: return format == .movText ? "srt" : "copy"
        }
    }

    public static func validate(_ tracks: [SubtitleTrack], container: SubtitleContainer, cutting: Bool) throws {
        guard !tracks.isEmpty else { throw SubtitleError.noTracks }
        if container == .mp4, tracks.contains(where: { !$0.format.isText }) { throw SubtitleError.bitmapNeedsMKV }
        if cutting, tracks.contains(where: { !$0.format.isText && !$0.isEmbedded }) { throw SubtitleError.bitmapCannotBeCut }
    }

    /// 输出文件名：`原名_subs.mp4`；同时剪切时 `原名_cut_01m23.456s-01m35.456s_subs.mp4`。
    public static func outputFileName(source: URL, range: CutRange?, container: SubtitleContainer) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        let cut = range.map { "_cut_\(OutputNaming.timeTag($0.start))-\(OutputNaming.timeTag($0.end))" } ?? ""
        return "\(base)\(cut)_subs.\(container.rawValue)"
    }

    /// 第一步（只在同时剪切时）：快速剪切成临时 MKV，带上要保留的原有字幕流。
    /// 输出时间 0 对应源文件的实际起点（起点之前最近的关键帧）。
    public static func cutArguments(source: URL, range: CutRange, embeddedStreams: [Int], output: URL) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n"] + FFmpegProgress.arguments
        args += ["-ss", seconds(range.start), "-i", source.path, "-t", seconds(range.duration)]
        args += ["-map", "0:v:0", "-map", "0:a?"]
        for index in embeddedStreams { args += ["-map", "0:\(index)"] }
        args += ["-c", "copy", "-avoid_negative_ts", "make_zero", "-f", "matroska", output.path]
        return args
    }

    /// 一条要放进 ffmpeg 的外部字幕输入。
    public struct ExternalInput: Sendable, Equatable {
        public var track: SubtitleTrack
        /// 已经转成 UTF-8 / 平移过的文件（图形字幕就是原文件）。
        public var file: URL

        public init(track: SubtitleTrack, file: URL) {
            self.track = track
            self.file = file
        }
    }

    /// 第二步：视频和音频直接复制，加上字幕。
    ///
    /// - Parameters:
    ///   - base: 源视频，或第一步剪出来的临时 MKV。
    ///   - embedded: 原有字幕轨道和它们在 `base` 里的选择器（源视频是 `0:<序号>`，临时 MKV 是 `0:s:<i>`）。
    ///   - external: 外部字幕文件，按顺序放在原有字幕后面。
    public static func muxArguments(
        base: URL, embedded: [(track: SubtitleTrack, selector: String)], external: [ExternalInput],
        container: SubtitleContainer, videoCodec: String?, output: URL
    ) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n"] + FFmpegProgress.arguments
        args += ["-i", base.path]
        for input in external {
            // VobSub 的输入是 .idx；字幕文件都按 UTF-8 读。
            if input.track.format.isText { args += ["-sub_charenc", "UTF-8"] }
            args += ["-i", input.file.path]
        }
        args += ["-map", "0:v:0", "-map", "0:a?"]
        for item in embedded { args += ["-map", item.selector] }
        for i in external.indices { args += ["-map", "\(i + 1):0"] }
        args += ["-c:v", "copy", "-c:a", "copy"]

        let tracks = embedded.map(\.track) + external.map(\.track)
        let defaultIndex = tracks.firstIndex(where: \.isDefault)
        for (n, track) in tracks.enumerated() {
            args += ["-c:s:\(n)", outputCodec(for: track.format, container: container)]
            args += ["-metadata:s:s:\(n)", "language=\(SubtitleLanguages.normalize(track.language))"]
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                args += ["-metadata:s:s:\(n)", "title=\(title)"]
                // MP4 里播放器显示的轨道名是 handler_name。
                if container == .mp4 { args += ["-metadata:s:s:\(n)", "handler_name=\(title)"] }
            }
            args += ["-disposition:s:\(n)", n == defaultIndex ? "default" : "0"]
        }
        if container == .mp4 {
            if videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
            args += ["-movflags", "+faststart", "-f", "mp4"]
        } else {
            args += ["-f", "matroska"]
        }
        args.append(output.path)
        return args
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

/// 一次加字幕的请求。
public struct SubtitleJob: Sendable, Equatable {
    public var source: URL
    /// 要写入的轨道（原有轨道里被去掉的不在这里）。
    public var tracks: [SubtitleTrack]
    public var container: SubtitleContainer
    /// 同时只导出这个区间（快速剪切）；nil 表示整段。
    public var range: CutRange?
    public var outputDirectory: URL?
    public var copyMetadata: Bool
    public var shiftRecordingDate: Bool

    public init(
        source: URL, tracks: [SubtitleTrack], container: SubtitleContainer, range: CutRange? = nil,
        outputDirectory: URL? = nil, copyMetadata: Bool = true, shiftRecordingDate: Bool = true
    ) {
        self.source = source
        self.tracks = tracks
        self.container = container
        self.range = range
        self.outputDirectory = outputDirectory
        self.copyMetadata = copyMetadata
        self.shiftRecordingDate = shiftRecordingDate
    }
}

public struct SubtitleResult: Sendable, Equatable {
    public var output: URL
    /// 同时剪切时的实际起点（字幕按它平移）。
    public var actualStart: Double?
    public var warnings: [String]
}

/// 加字幕：准备字幕文件（转 UTF-8、平移）→（需要时）快速剪切 → 封装 → 复制元数据 → 不覆盖地改名。
/// 视频和音频不重新编码；原文件永远不变；取消或失败时只删除自己的临时文件。
public struct SubtitleExporter: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared) {
        self.runner = runner
        self.locator = locator
    }

    public func export(
        _ job: SubtitleJob, info: MediaInfo, progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> SubtitleResult {
        try SubtitlePlanner.validate(job.tracks, container: job.container, cutting: job.range != nil)
        let range = try job.range.map { try CutPlanner.validate($0, duration: info.bestDuration) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SkimCut-subs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 同时剪切：实际起点是起点之前最近的关键帧，字幕按它平移。
        var actualStart: Double?
        if let range {
            let k = try await Keyframes.keyframe(
                atOrBefore: range.start, in: job.source, startTime: info.startTime, runner: runner, locator: locator)
            actualStart = CutPlanner.fastActualStart(requested: range.start, keyframeAtOrBefore: k)
        }

        // 外部字幕：转成 UTF-8，需要时平移。
        var external: [SubtitlePlanner.ExternalInput] = []
        for (i, track) in job.tracks.enumerated() {
            guard case .file(let url) = track.source else { continue }
            try Task.checkCancellation()
            guard track.format.isText else {
                external.append(.init(track: track, file: url))
                continue
            }
            let charset: String
            if let known = track.charset {
                charset = known
            } else {
                charset = try await SubtitleEncoding.detect(url, runner: runner, locator: locator)
            }
            // uchardet 没认出来、内容也不是合法的 UTF-8：不猜，直接告诉用户。
            if SubtitleEncoding.isUnknown(charset), String(data: try Data(contentsOf: url), encoding: .utf8) == nil {
                throw SubtitleError.unknownEncoding(url.lastPathComponent)
            }
            var text = try await SubtitleEncoding.readUTF8(url, charset: charset, runner: runner, locator: locator)
            if let range, let start = actualStart {
                text = SubtitleShifter.shift(text, format: track.format, by: start, duration: range.end - start)
            }
            let ext = track.format == .vtt ? "vtt" : track.format.rawValue
            let prepared = work.appendingPathComponent("track\(i).\(ext)")
            try Data(text.utf8).write(to: prepared)
            external.append(.init(track: track, file: prepared))
        }

        // 第一步（同时剪切时）：快速剪切成临时 MKV。
        let embeddedTracks = job.tracks.compactMap { track -> (SubtitleTrack, Int)? in
            if case .embedded(let index) = track.source { return (track, index) }
            return nil
        }
        var base = job.source
        var embedded: [(track: SubtitleTrack, selector: String)] = embeddedTracks.map { ($0.0, "0:\($0.1)") }
        let outputDuration = range.map { $0.end - (actualStart ?? $0.start) } ?? info.bestDuration
        let twoSteps = range != nil
        if let range {
            let cut = work.appendingPathComponent("cut.mkv")
            let args = SubtitlePlanner.cutArguments(
                source: job.source, range: range, embeddedStreams: embeddedTracks.map(\.1), output: cut)
            try await runFFmpeg(args, partial: cut, total: outputDuration) { p in
                progress?(p.map { $0 * 0.5 })
            }
            base = cut
            embedded = embeddedTracks.enumerated().map { ($0.element.0, "0:s:\($0.offset)") }
        }

        // 第二步：封装字幕，写进输出目录里的临时文件。
        let directory = job.outputDirectory ?? job.source.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(directory.appendingPathComponent(
            SubtitlePlanner.outputFileName(source: job.source, range: range, container: job.container)))
        let temp = CutExporter.temporaryURL(for: output)
        let args = SubtitlePlanner.muxArguments(
            base: base, embedded: embedded, external: external, container: job.container,
            videoCodec: info.videoStream?.codecName, output: temp)
        try await runFFmpeg(args, partial: temp, total: outputDuration) { p in
            progress?(p.map { twoSteps ? 0.5 + $0 * 0.49 : min($0, 0.99) })
        }

        do {
            if job.copyMetadata, MetadataCopier.supports(job.source), MetadataCopier.supports(temp) {
                try Task.checkCancellation()
                let shift = job.shiftRecordingDate ? actualStart : nil
                try await MetadataCopier(runner: runner, locator: locator)
                    .copy(from: job.source, to: temp, shiftDatesBy: shift)
            }
            try Task.checkCancellation()
            let final = try CutExporter.moveWithoutOverwriting(temp, to: output)
            progress?(1)
            return SubtitleResult(
                output: final, actualStart: actualStart,
                warnings: SubtitlePlanner.warnings(job.tracks, container: job.container))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private func runFFmpeg(
        _ args: [String], partial: URL, total: Double?, progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let parser = LockedParser()
        _ = try await runner.run(try locator.command(.ffmpeg, args), partialOutputs: [partial], onStdoutLine: { line in
            if let snapshot = parser.consume(line) {
                progress(snapshot.fraction(totalDuration: total))
            }
        })
    }
}
