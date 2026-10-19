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

    /// - Parameter sourceHasSubtitles: 源视频里本来有字幕。这时允许一条都不留，生成去掉字幕的版本。
    public static func validate(
        _ tracks: [SubtitleTrack], container: SubtitleContainer, cutting: Bool, sourceHasSubtitles: Bool = false
    ) throws {
        guard !tracks.isEmpty || sourceHasSubtitles else { throw SubtitleError.noTracks }
        if container == .mp4, tracks.contains(where: { !$0.format.isText }) { throw SubtitleError.bitmapNeedsMKV }
        if cutting, tracks.contains(where: { !$0.format.isText && !$0.isEmbedded }) { throw SubtitleError.bitmapCannotBeCut }
    }

    /// 输出文件名：`原名_subs.mp4`；同时剪切时 `原名_cut_01m23.456s-01m35.456s_subs.mp4`；
    /// 一条字幕都不留时是 `原名_nosubs.mp4`。
    public static func outputFileName(source: URL, range: CutRange?, container: SubtitleContainer, empty: Bool = false) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        let cut = range.map { "_cut_\(OutputNaming.timeTag($0.start))-\(OutputNaming.timeTag($0.end))" } ?? ""
        return "\(base)\(cut)_\(empty ? "nosubs" : "subs").\(container.rawValue)"
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

    /// 输出里的一条字幕：来自 `base` 里的某条流，或者一个字幕文件。
    public struct MuxTrack: Sendable, Equatable {
        public enum Input: Sendable, Equatable {
            /// `base` 里的流（源视频是 `0:<序号>`，临时 MKV 是 `0:s:<i>`）。
            case base(selector: String)
            /// 已经转成 UTF-8 / 平移过的字幕文件（图形字幕就是原文件）。
            case file(URL)
            /// 另一个文件里的某条流（一次导出时，原有字幕从原文件取）。
            case stream(URL, index: Int)
        }

        public var track: SubtitleTrack
        public var input: Input

        public init(track: SubtitleTrack, input: Input) {
            self.track = track
            self.input = input
        }
    }

    /// 第二步：视频和音频直接复制，按 `tracks` 的顺序加上字幕（顺序就是用户在列表里排的顺序）。
    /// `tracks` 为空时生成不带字幕的版本。
    public static func muxArguments(
        base: URL, tracks: [MuxTrack], container: SubtitleContainer, videoCodec: String?, output: URL
    ) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n"] + FFmpegProgress.arguments
        args += ["-i", base.path]
        var maps: [String] = []
        var nextInput = 1
        for item in tracks {
            switch item.input {
            case .base(let selector):
                maps.append(selector)
            case .file(let url):
                // VobSub 的输入是 .idx；文字字幕都按 UTF-8 读。
                if item.track.format.isText { args += ["-sub_charenc", "UTF-8"] }
                args += ["-i", url.path]
                maps.append("\(nextInput):0")
                nextInput += 1
            case .stream(let url, let index):
                args += ["-i", url.path]
                maps.append("\(nextInput):\(index)")
                nextInput += 1
            }
        }
        args += ["-map", "0:v:0", "-map", "0:a?"]
        for m in maps { args += ["-map", m] }
        args += ["-c:v", "copy", "-c:a", "copy"]

        let defaultIndex = tracks.firstIndex(where: \.track.isDefault)
        for (n, item) in tracks.enumerated() {
            let track = item.track
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

    /// 从临时 MKV 里取出一条文字字幕（已经和剪好的画面同步），之后在 Swift 里截到终点。
    /// 返回参数和取出后的格式（mov_text 取成 SRT）。
    public static func extractArguments(from file: URL, subtitleIndex: Int, format: SubtitleFormat, output: URL) -> [String] {
        let (codec, muxer) = extractionCodec(for: format)
        return ["-hide_banner", "-nostdin", "-v", "error", "-y", "-i", file.path,
                "-map", "0:s:\(subtitleIndex)", "-c:s", codec, "-f", muxer, output.path]
    }

    /// 取出时用的编码和格式。
    public static func extractionCodec(for format: SubtitleFormat) -> (codec: String, muxer: String) {
        switch format {
        case .ass, .ssa: return ("ass", "ass")
        case .vtt: return ("webvtt", "webvtt")
        default: return ("srt", "srt")
        }
    }

    /// 取出后的格式。
    public static func extractedFormat(for format: SubtitleFormat) -> SubtitleFormat {
        switch format {
        case .ass, .ssa: return .ass
        case .vtt: return .vtt
        default: return .srt
        }
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
        try SubtitlePlanner.validate(
            job.tracks, container: job.container, cutting: job.range != nil,
            sourceHasSubtitles: !info.subtitleStreams.isEmpty)
        let range = try job.range.map { try CutPlanner.validate($0, duration: info.bestDuration) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SkimCut-subs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let embeddedIndices = job.tracks.compactMap { track -> Int? in
            if case .embedded(let index) = track.source { return index }
            return nil
        }

        // 第一步（同时剪切时）：快速剪切成临时 MKV。实际起点是起点之前最近的关键帧。
        var base = job.source
        var actualStart: Double?
        /// 字幕文件里的时间减去多少秒才是输出里的时间；输出里的终点。
        var timing: (offset: Double, end: Double)?
        let twoSteps = range != nil
        var outputDuration = info.bestDuration
        if let range {
            let k = try await Keyframes.keyframe(
                atOrBefore: range.start, in: job.source, startTime: info.startTime, runner: runner, locator: locator)
            let start = CutPlanner.fastActualStart(requested: range.start, keyframeAtOrBefore: k)
            actualStart = start
            outputDuration = range.end - start
            let cut = work.appendingPathComponent("cut.mkv")
            let args = SubtitlePlanner.cutArguments(
                source: job.source, range: range, embeddedStreams: embeddedIndices, output: cut)
            try await runFFmpeg(args, partial: cut, total: outputDuration) { p in
                progress?(p.map { $0 * 0.5 })
            }
            base = cut
            // 剪出来的文件里，第一帧视频不一定在 0 秒（有 B 帧时常见 0.05–0.08 秒）。字幕要对齐画面：
            // 字幕文件里的时间（播放器按相对文件开头的时间显示）减去实际起点，再加上第一帧视频的时间 v0。
            let cutInfo = try await MediaInfo.probe(cut, runner: runner, locator: locator)
            let v0 = cutInfo.videoStream?.startTime ?? 0
            timing = (offset: start - v0, end: range.end - start + v0)
        }

        // 每条轨道准备好输入（顺序就是列表的顺序）。
        var muxTracks: [SubtitlePlanner.MuxTrack] = []
        var embeddedPosition = 0
        for (i, track) in job.tracks.enumerated() {
            try Task.checkCancellation()
            switch track.source {
            case .embedded(let index):
                defer { embeddedPosition += 1 }
                guard let timing, track.format.isText else {
                    // 不剪切：直接从源视频复制。剪切时的图形字幕：跟着第一步复制（不能截尾）。
                    let selector = twoSteps ? "0:s:\(embeddedPosition)" : "0:\(index)"
                    muxTracks.append(.init(track: track, input: .base(selector: selector)))
                    continue
                }
                // 剪切时的原有文字字幕：从临时 MKV 取出来（已经和画面同步），再和外部字幕一样截到终点。
                let format = SubtitlePlanner.extractedFormat(for: track.format)
                let extracted = work.appendingPathComponent("embedded\(i).\(format == .vtt ? "vtt" : format.rawValue)")
                _ = try await runner.run(try locator.command(.ffmpeg, SubtitlePlanner.extractArguments(
                    from: base, subtitleIndex: embeddedPosition, format: track.format, output: extracted)))
                let text = SubtitleShifter.shift(
                    String(decoding: try Data(contentsOf: extracted), as: UTF8.self),
                    format: format, by: 0, duration: timing.end)
                try Data(text.utf8).write(to: extracted)
                var converted = track
                converted.format = format
                muxTracks.append(.init(track: converted, input: .file(extracted)))
            case .file(let url):
                muxTracks.append(try await prepareFile(track, url: url, timing: timing, work: work, number: i))
            }
        }

        // 第二步：封装字幕，写进输出目录里的临时文件。
        let directory = job.outputDirectory ?? job.source.deletingLastPathComponent()
        let output = OutputNaming.uniqueURL(directory.appendingPathComponent(SubtitlePlanner.outputFileName(
            source: job.source, range: range, container: job.container, empty: job.tracks.isEmpty)))
        let temp = CutExporter.temporaryURL(for: output)
        let args = SubtitlePlanner.muxArguments(
            base: base, tracks: muxTracks, container: job.container,
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

    /// 外部字幕文件：文字字幕转成 UTF-8（需要时平移、截尾）写进临时文件；图形字幕直接用原文件。
    private func prepareFile(
        _ track: SubtitleTrack, url: URL, timing: (offset: Double, end: Double)?, work: URL, number i: Int
    ) async throws -> SubtitlePlanner.MuxTrack {
        guard track.format.isText else { return .init(track: track, input: .file(url)) }
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
        if let timing {
            text = SubtitleShifter.shift(text, format: track.format, by: timing.offset, duration: timing.end)
        }
        let ext = track.format == .vtt ? "vtt" : track.format.rawValue
        let prepared = work.appendingPathComponent("track\(i).\(ext)")
        try Data(text.utf8).write(to: prepared)
        return .init(track: track, input: .file(prepared))
    }

    /// 一次导出用：把字幕封装到已经处理过的 `base`（剪切、统一音量之后的文件）上，写到 `output`。
    ///
    /// - 原有字幕轨道从原文件 `original` 取（`base` 里的字幕流不用）；
    /// - `cut` 不为 nil 时（剪切过），字幕按实际起点平移、对齐 `base` 的第一帧视频，并截到终点；
    ///   原有的文字字幕先从原文件取出来再平移，原有的图形字幕不能平移（`validate` 已经拒绝）。
    public func mux(
        onto base: URL, original: URL, originalInfo: MediaInfo, tracks: [SubtitleTrack], container: SubtitleContainer,
        cut: (actualStart: Double, end: Double)?, output: URL, work: URL,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        let baseInfo = try await MediaInfo.probe(base, runner: runner, locator: locator)
        var timing: (offset: Double, end: Double)?
        if let cut {
            let v0 = baseInfo.videoStream?.startTime ?? 0
            timing = (offset: cut.actualStart - v0, end: cut.end - cut.actualStart + v0)
        }
        let subtitleOrder = originalInfo.subtitleStreams.map(\.index)
        var muxTracks: [SubtitlePlanner.MuxTrack] = []
        for (i, track) in tracks.enumerated() {
            try Task.checkCancellation()
            switch track.source {
            case .embedded(let index):
                guard let timing, track.format.isText, let k = subtitleOrder.firstIndex(of: index) else {
                    muxTracks.append(.init(track: track, input: .stream(original, index: index)))
                    continue
                }
                let format = SubtitlePlanner.extractedFormat(for: track.format)
                let extracted = work.appendingPathComponent("embedded\(i).\(format == .vtt ? "vtt" : format.rawValue)")
                _ = try await runner.run(try locator.command(.ffmpeg, SubtitlePlanner.extractArguments(
                    from: original, subtitleIndex: k, format: track.format, output: extracted)))
                let text = SubtitleShifter.shift(
                    String(decoding: try Data(contentsOf: extracted), as: UTF8.self),
                    format: format, by: timing.offset, duration: timing.end)
                try Data(text.utf8).write(to: extracted)
                var converted = track
                converted.format = format
                muxTracks.append(.init(track: converted, input: .file(extracted)))
            case .file(let url):
                muxTracks.append(try await prepareFile(track, url: url, timing: timing, work: work, number: i))
            }
        }
        let args = SubtitlePlanner.muxArguments(
            base: base, tracks: muxTracks, container: container,
            videoCodec: baseInfo.videoStream?.codecName, output: output)
        try await runFFmpeg(args, partial: output, total: baseInfo.bestDuration) { p in progress?(p) }
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
