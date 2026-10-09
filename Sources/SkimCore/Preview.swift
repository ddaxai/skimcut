import Foundation

/// AVPlayer 打不开的文件怎么预览。导出时永远用原始文件，预览文件只给播放器和缩略图用。
public enum PreviewStrategy: String, Sendable, Equatable, CaseIterable {
    /// AVPlayer 可以直接播放原文件。
    case native
    /// `-c copy` 转封装成临时 MP4（H.264/HEVC + AAC）。
    case remux
    /// 重新编码成低分辨率的预览代理。
    case proxy
}

/// 生成代理用的视频编码器。
public enum PreviewEncoder: String, Sendable, Equatable, CaseIterable {
    /// macOS：硬件编码。
    case videoToolbox = "h264_videotoolbox"
    /// Linux 测试（以及 VideoToolbox 不可用时）：软件编码。
    case libx264

    public static var platformDefault: PreviewEncoder {
        #if os(macOS)
        .videoToolbox
        #else
        .libx264
        #endif
    }
}

public enum PreviewError: Error, Sendable, Equatable, LocalizedError {
    case noVideoStream

    public var errorDescription: String? {
        switch self {
        case .noVideoStream: return "这个文件里没有视频画面，无法预览。"
        }
    }
}

/// 决定预览方式，并生成 ffmpeg 参数（参数一律是数组，不经过 shell）。
public enum PreviewPlanner {
    /// 代理的最大高度。
    public static let proxyMaxHeight = 540
    /// 代理的关键帧间隔（秒）：短 GOP 让 skimming 时的 seek 更快。
    public static let proxyKeyframeInterval = 0.5

    /// - Parameter nativelyPlayable: AVFoundation 是否能直接播放（App 里用 `AVURLAsset.isPlayable` 判断）。
    public static func strategy(for info: MediaInfo, nativelyPlayable: Bool) throws -> PreviewStrategy {
        guard let video = info.videoStream else { throw PreviewError.noVideoStream }
        if nativelyPlayable { return .native }
        return canRemux(video: video, audio: info.audioStreams.first) ? .remux : .proxy
    }

    /// H.264（8-bit 4:2:0）或 HEVC（8/10-bit 4:2:0），音频是 AAC 或者没有音频：可以直接复制成 MP4。
    public static func canRemux(video: MediaStream, audio: MediaStream?) -> Bool {
        let videoOK: Bool
        switch video.codecName {
        case "h264":
            videoOK = ["yuv420p", "yuvj420p"].contains(video.pixelFormat ?? "")
        case "hevc":
            videoOK = ["yuv420p", "yuvj420p", "yuv420p10le"].contains(video.pixelFormat ?? "")
        default:
            videoOK = false
        }
        guard videoOK else { return false }
        guard let audio else { return true }
        return audio.codecName == "aac"
    }

    /// 命令行里没有 AVFoundation 时的猜测：MP4/MOV 容器里的 H.264/HEVC + 常见音频，AVPlayer 一般能直接播放。
    /// App 不用这个函数，而是直接问 AVFoundation。
    public static func guessNativelyPlayable(_ info: MediaInfo) -> Bool {
        guard info.isQuickTimeFamily, let video = info.videoStream else { return false }
        guard canRemux(video: video, audio: nil) else { return false }
        if video.codecName == "hevc", video.codecTagString != "hvc1" { return false }
        guard let audio = info.audioStreams.first else { return true }
        return ["aac", "alac", "mp3", "ac3", "eac3", "pcm_s16le", "pcm_s24le"].contains(audio.codecName ?? "")
    }

    /// 转封装：`-c copy`，只取第一条视频和第一条音频。HEVC 必须带 `hvc1` 标签，QuickTime 才能打开。
    public static func remuxArguments(input: URL, output: URL, info: MediaInfo) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y"] + FFmpegProgress.arguments
        args += ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]
        if info.videoStream?.codecName == "hevc" {
            args += ["-tag:v", "hvc1"]
        }
        args += ["-sn", "-dn", "-movflags", "+faststart", "-f", "mp4", output.path]
        return args
    }

    /// 低分辨率代理：高度不超过 540，GOP 约 0.5 秒，8-bit 4:2:0 H.264 + AAC 立体声。
    public static func proxyArguments(input: URL, output: URL, info: MediaInfo, encoder: PreviewEncoder) -> [String] {
        let fps = info.videoStream?.frameRate ?? 30
        let gop = max(1, Int((fps * proxyKeyframeInterval).rounded()))
        var args = ["-hide_banner", "-nostdin", "-y"] + FFmpegProgress.arguments
        args += ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?"]
        // 高度取偶数并且不放大；宽度 -2 = 按比例并取偶数。
        args += ["-vf", "scale=w=-2:h='min(\(proxyMaxHeight),trunc(ih/2)*2)',format=yuv420p"]
        switch encoder {
        case .videoToolbox:
            // allow_sw：没有硬件编码器时（例如虚拟机）允许系统的软件编码器。
            args += ["-c:v", "h264_videotoolbox", "-b:v", "4M", "-allow_sw", "1"]
        case .libx264:
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "26"]
        }
        args += ["-g", String(gop)]
        args += ["-c:a", "aac", "-b:a", "128k", "-ac", "2"]
        args += ["-sn", "-dn", "-movflags", "+faststart", "-f", "mp4", output.path]
        return args
    }

    public static func arguments(
        strategy: PreviewStrategy, input: URL, output: URL, info: MediaInfo, encoder: PreviewEncoder
    ) -> [String]? {
        switch strategy {
        case .native: return nil
        case .remux: return remuxArguments(input: input, output: output, info: info)
        case .proxy: return proxyArguments(input: input, output: output, info: info, encoder: encoder)
        }
    }
}

/// 预览临时文件的存放位置：`$TMPDIR/SkimCut-previews/session-<pid>-<uuid>/`。
///
/// - 关闭视频时删除对应的文件；
/// - 退出 App 时删除整个会话目录；
/// - 启动时清理进程已经不存在的旧会话目录（上次崩溃留下的）。
public final class PreviewFileStore: @unchecked Sendable {
    public static let rootName = "SkimCut-previews"

    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
    }

    public let root: URL
    public let sessionDirectory: URL

    public init(root: URL = PreviewFileStore.defaultRoot, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.root = root
        self.sessionDirectory = root.appendingPathComponent(
            "session-\(processID)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// 为一个源文件分配预览文件路径（目录按需创建，文件本身不创建）。
    public func makePreviewURL(for source: URL, strategy: PreviewStrategy) throws -> URL {
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let name = "\(base)-\(strategy.rawValue)-\(UUID().uuidString.prefix(8)).mp4"
        return sessionDirectory.appendingPathComponent(name)
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 删除本次会话的全部预览文件。
    public func removeSessionDirectory() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    /// 删除进程已经不存在的旧会话目录。返回删除的目录。
    @discardableResult
    public static func purgeStale(
        root: URL = PreviewFileStore.defaultRoot,
        isAlive: (Int32) -> Bool = { ProcessKiller.isAlive($0) }
    ) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var removed: [URL] = []
        for dir in items {
            let parts = dir.lastPathComponent.split(separator: "-")
            guard parts.count >= 3, parts[0] == "session", let pid = Int32(parts[1]) else { continue }
            if !isAlive(pid) {
                try? fm.removeItem(at: dir)
                removed.append(dir)
            }
        }
        return removed
    }
}

/// 运行转封装或代理生成。
public struct PreviewBuilder: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator
    public var encoder: PreviewEncoder

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared, encoder: PreviewEncoder = .platformDefault) {
        self.runner = runner
        self.locator = locator
        self.encoder = encoder
    }

    /// 生成预览文件。失败或取消时删除半成品。
    /// - Parameter progress: 0…1 的进度；时长未知时为 nil。
    public func build(
        source: URL, info: MediaInfo, strategy: PreviewStrategy, output: URL,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        guard let args = PreviewPlanner.arguments(
            strategy: strategy, input: source, output: output, info: info, encoder: encoder)
        else { return }
        let command = try locator.command(.ffmpeg, args)
        let total = info.bestDuration
        let parser = ProgressParserBox()
        _ = try await runner.run(command, partialOutputs: [output], onStdoutLine: { line in
            if let snapshot = parser.consume(line), let progress {
                progress(snapshot.fraction(totalDuration: total))
            }
        })
    }
}

/// 在读输出的线程里串行使用，加锁只是为了满足 Sendable。
private final class ProgressParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = FFmpegProgressParser()

    func consume(_ line: String) -> FFmpegProgress? {
        lock.lock()
        defer { lock.unlock() }
        return parser.consume(line: line)
    }
}
