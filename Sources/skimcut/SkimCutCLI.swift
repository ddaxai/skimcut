import ArgumentParser
import Foundation
import SkimCore

@main
struct SkimCutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skimcut",
        abstract: "SkimCut 命令行工具：提供 SkimCore 的全部功能。",
        version: SkimCoreInfo.version,
        subcommands: [Tools.self, Probe.self, Preview.self, KeyframesCommand.self, Cut.self, Subs.self]
    )
}

/// `skimcut tools`：列出每个外部工具的路径和版本。
struct Tools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "检查外部工具的位置和版本。")

    @Flag(help: "以 JSON 格式输出。")
    var json = false

    @Flag(help: "缺少任何工具时以非零状态退出。")
    var strict = false

    func run() async throws {
        let statuses = await ToolInventory.check()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(statuses), as: UTF8.self))
        } else {
            for s in statuses {
                let name = s.tool.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)
                if let path = s.path {
                    print("\(name)\(s.version ?? "?")\t\(path)")
                } else {
                    print("\(name)未找到\t安装：\(s.tool.installHint)")
                }
            }
        }
        if strict, statuses.contains(where: { !$0.isAvailable }) {
            throw ExitCode(1)
        }
    }
}

/// `skimcut probe <文件>`：显示媒体信息。
struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "显示视频的时长、容器和各条流的信息（ffprobe）。")

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Flag(help: "输出 ffprobe 的原始 JSON。")
    var json = false

    func run() async throws {
        if json {
            let command = try ToolLocator.shared.command(.ffprobe, MediaInfo.probeArguments(for: file))
            print(try await ToolRunner().output(command), terminator: "")
            return
        }
        let info = try await MediaInfo.probe(file)
        print("容器：\(info.formatName)")
        print("时长：\(info.bestDuration.map(Timecode.format) ?? "未知")")
        for s in info.streams {
            var parts = ["#\(s.index)", s.codecType, s.codecName ?? "?"]
            if let tag = s.codecTagString, !tag.hasPrefix("[") { parts.append("tag=\(tag)") }
            if let w = s.width, let h = s.height { parts.append("\(w)x\(h)") }
            if let fmt = s.pixelFormat { parts.append(fmt) }
            if let fps = s.frameRate, s.isVideo { parts.append(String(format: "%.3f fps", fps)) }
            if s.isHDR { parts.append("HDR") }
            if s.isAttachedPicture { parts.append("封面图") }
            if let lang = s.language { parts.append("lang=\(lang)") }
            print(parts.joined(separator: "  "))
        }
        let strategy = try PreviewPlanner.strategy(for: info, nativelyPlayable: PreviewPlanner.guessNativelyPlayable(info))
        print("预览方式（推测）：\(strategy.rawValue)")
    }
}

/// `skimcut preview <文件>`：生成 App 用的预览文件（转封装或低分辨率代理）。
struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "生成预览文件：能转封装就 -c copy，否则生成低分辨率代理。")

    enum StrategyOption: String, ExpressibleByArgument, CaseIterable {
        case auto, remux, proxy
    }

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(name: .shortAndLong, help: "输出文件（.mp4）。默认放在原文件旁边：原名_preview.mp4。",
            transform: { URL(fileURLWithPath: $0) })
    var output: URL?

    @Option(help: "预览方式：auto、remux、proxy。")
    var strategy: StrategyOption = .auto

    @Option(help: "代理的视频编码器：h264_videotoolbox 或 libx264。")
    var encoder: String = PreviewEncoder.platformDefault.rawValue

    func run() async throws {
        guard let enc = PreviewEncoder(rawValue: encoder) else {
            throw ValidationError("不支持的编码器：\(encoder)")
        }
        let info = try await MediaInfo.probe(file)
        let chosen: PreviewStrategy
        switch strategy {
        case .auto:
            chosen = try PreviewPlanner.strategy(for: info, nativelyPlayable: PreviewPlanner.guessNativelyPlayable(info))
        case .remux:
            guard let v = info.videoStream, PreviewPlanner.canRemux(video: v, audio: info.audioStreams.first) else {
                throw ValidationError("这个文件不能直接转封装（需要 H.264/HEVC + AAC），请用 --strategy proxy。")
            }
            chosen = .remux
        case .proxy:
            guard info.videoStream != nil else { throw PreviewError.noVideoStream }
            chosen = .proxy
        }
        guard chosen != .native else {
            print("AVPlayer 应该可以直接播放，不需要预览文件。如果确实打不开，加 --strategy remux 或 proxy。")
            return
        }
        let out = output ?? file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_preview.mp4")
        guard !FileManager.default.fileExists(atPath: out.path) else {
            throw ValidationError("输出文件已存在：\(out.path)")
        }
        print("方式：\(chosen.rawValue)  →  \(out.path)")
        let last = LastPercent()
        try await PreviewBuilder(encoder: enc).build(source: file, info: info, strategy: chosen, output: out) { p in
            if let p, last.update(Int(p * 100)) {
                FileHandle.standardError.write(Data("\r进度 \(Int(p * 100))%".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("完成")
    }
}

/// 只在百分比变化时打印。
private final class LastPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    func update(_ new: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard new != value else { return false }
        value = new
        return true
    }
}

/// `skimcut keyframes <文件> --around 83.5`：列出某个时间附近的关键帧。
struct KeyframesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyframes", abstract: "列出某个时间附近（往前 15 秒、共 20 秒）的关键帧。")

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(help: "时间，例如 83.456、1:23.456、00:01:23.456。", transform: parseTime)
    var around: Double = 0

    func run() async throws {
        let info = try await MediaInfo.probe(file)
        let command = try ToolLocator.shared.command(
            .ffprobe, Keyframes.arguments(for: file, around: around, startTime: info.startTime))
        let frames = Keyframes.parse(try await ToolRunner().output(command), startTime: info.startTime)
        for t in frames { print(Timecode.format(t)) }
        if let k = Keyframes.keyframe(atOrBefore: around, in: frames) {
            print("不晚于 \(Timecode.format(around)) 的最近关键帧：\(Timecode.format(k))")
        }
    }
}

/// `skimcut cut <文件> --start 1:23.456 --end 1:35.456 --mode precise`
struct Cut: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "把一段剪出来另存为新文件（原文件不变）。")

    enum ModeOption: String, ExpressibleByArgument, CaseIterable { case fast, precise }
    enum EncoderOption: String, ExpressibleByArgument, CaseIterable { case videotoolbox, software, lossless }

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(help: "起点，例如 83.456、1:23.456、00:01:23.456。", transform: parseTime)
    var start: Double

    @Option(help: "终点。和 --duration 二选一。", transform: parseTime)
    var end: Double?

    @Option(help: "时长。和 --end 二选一。", transform: parseTime)
    var duration: Double?

    @Option(help: "fast：-c copy（起点提前到关键帧）；precise：重新编码，精确到帧。")
    var mode: ModeOption = .precise

    @Option(help: "精确模式的编码器：videotoolbox（macOS 默认）、software、lossless（测试用）。")
    var encoder: EncoderOption?

    @Option(name: .customLong("output-dir"), help: "输出目录，默认放在原文件旁边。", transform: { URL(fileURLWithPath: $0) })
    var outputDirectory: URL?

    @Flag(name: .customLong("no-metadata"), help: "不从原文件复制元数据。")
    var noMetadata = false

    @Flag(name: .customLong("no-shift-date"), help: "录制时间不加上剪切起点。")
    var noShiftDate = false

    @Flag(name: .customLong("dry-run"), help: "只显示计划和 ffmpeg 命令，不执行。")
    var dryRun = false

    func validate() throws {
        guard (end == nil) != (duration == nil) else {
            throw ValidationError("--end 和 --duration 必须且只能给一个。")
        }
    }

    func run() async throws {
        let cutEncoder: CutEncoder
        switch encoder {
        case nil: cutEncoder = .platformDefault
        case .videotoolbox: cutEncoder = .videoToolbox
        case .software: cutEncoder = .software(lossless: false)
        case .lossless: cutEncoder = .software(lossless: true)
        }
        let range = CutRange(start: start, end: end ?? (start + (duration ?? 0)))
        let options = CutOptions(
            mode: mode == .fast ? .fast : .precise, outputDirectory: outputDirectory,
            copyMetadata: !noMetadata, shiftRecordingDate: !noShiftDate)
        let exporter = CutExporter(encoder: cutEncoder)
        let info = try await MediaInfo.probe(file)
        let plan = try await exporter.plan(source: file, info: info, range: range, options: options)

        print("区间：\(Timecode.format(plan.range.start)) – \(Timecode.format(plan.range.end))（\(options.mode.displayName)）")
        if let message = plan.leadInMessage { print(message) }
        if let description = plan.encoderDescription { print(description) }
        for warning in plan.warnings { print("注意：\(warning)") }
        print("输出：\(plan.output.path)")
        if dryRun {
            let ffmpeg = try ToolLocator.shared.command(.ffmpeg, plan.arguments)
            print(ffmpeg.displayString)
            return
        }
        let last = LastPercent()
        let result = try await exporter.export(plan) { p in
            if let p, last.update(Int(p * 100)) {
                FileHandle.standardError.write(Data("\r进度 \(Int(p * 100))%".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        if let dates = result.recordingDates, let keys = dates.keysCreationDate ?? dates.createDate {
            print("录制时间：\(keys.exifToolString)")
        }
        if result.output != plan.output { print("输出（原名字被占用，改为）：\(result.output.path)") }
        print("完成")
    }
}

/// `skimcut subs <视频> --add a.srt:chi:中文 --add b.ass:eng --format mkv`
struct Subs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把字幕封装进视频（软字幕，不烧录）。视频和音频不重新编码，原文件不变。")

    enum FormatOption: String, ExpressibleByArgument, CaseIterable { case mp4, mkv }

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(name: .customLong("add"), help: "字幕文件，可以写成 文件[:语言[:标题]]，例如 a.srt:chi:中文。可以重复。")
    var add: [String] = []

    @Option(help: "输出格式：mp4（文字字幕转 mov_text，ASS 样式丢失）或 mkv（保留原格式和样式）。")
    var format: FormatOption = .mkv

    @Option(name: .customLong("default"), help: "第几条字幕是默认轨道（从 1 开始，按“原有轨道 + 新加轨道”的顺序）。")
    var defaultTrack: Int?

    @Flag(name: .customLong("drop-existing"), help: "去掉源视频里已有的字幕轨道（默认保留）。")
    var dropExisting = false

    @Option(help: "同时只导出这一段（快速剪切），起点。", transform: parseTime)
    var start: Double?

    @Option(help: "同时剪切时的终点。", transform: parseTime)
    var end: Double?

    @Option(name: .customLong("output-dir"), help: "输出目录，默认放在原文件旁边。", transform: { URL(fileURLWithPath: $0) })
    var outputDirectory: URL?

    func validate() throws {
        guard (start == nil) == (end == nil) else { throw ValidationError("--start 和 --end 要一起给。") }
    }

    func run() async throws {
        let info = try await MediaInfo.probe(file)
        var tracks = dropExisting ? [] : info.subtitleStreams.compactMap(SubtitleTrack.embedded)
        for spec in add {
            let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let url = URL(fileURLWithPath: parts[0])
            guard let format = SubtitleFormat.detect(url) else {
                throw ValidationError("不支持的字幕文件：\(parts[0])（支持 SRT、ASS、SSA、VTT、SUP、IDX/SUB）")
            }
            var track = SubtitleTrack(source: .file(url), format: format)
            if parts.count > 1, !parts[1].isEmpty { track.language = SubtitleLanguages.normalize(parts[1]) }
            if parts.count > 2 { track.title = parts[2] }
            if format.isText {
                track.charset = try await SubtitleEncoding.detect(url)
                print("\(url.lastPathComponent)：\(SubtitleEncoding.displayName(track.charset ?? ""))")
            }
            tracks.append(track)
        }
        if let n = defaultTrack {
            guard tracks.indices.contains(n - 1) else { throw ValidationError("--default 超出范围（共 \(tracks.count) 条）") }
            for i in tracks.indices { tracks[i].isDefault = (i == n - 1) }
        }
        let container: SubtitleContainer = format == .mp4 ? .mp4 : .mkv
        for warning in SubtitlePlanner.warnings(tracks, container: container) { print("注意：\(warning)") }
        let range = start.map { CutRange(start: $0, end: end ?? $0) }
        let job = SubtitleJob(source: file, tracks: tracks, container: container, range: range, outputDirectory: outputDirectory)
        let last = LastPercent()
        let result = try await SubtitleExporter().export(job, info: info) { p in
            if let p, last.update(Int(p * 100)) {
                FileHandle.standardError.write(Data("\r进度 \(Int(p * 100))%".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        if let k = result.actualStart, let range {
            print(String(format: "实际起点 %@（提前 %.3f 秒），字幕已按它平移。", Timecode.format(k), range.start - k))
        }
        print("输出：\(result.output.path)")
    }
}

/// 解析命令行里的时间。
private func parseTime(_ text: String) throws -> Double {
    guard let t = Timecode.parse(text) else {
        throw ValidationError("无法识别的时间：\(text)（例如 83.456、1:23.456、00:01:23.456）")
    }
    return t
}
