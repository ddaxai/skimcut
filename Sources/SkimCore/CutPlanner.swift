import Foundation

/// 剪切模式。
public enum CutMode: String, Sendable, Equatable, CaseIterable, Codable {
    /// `-c copy`：不重新编码，起点会提前到关键帧。
    case fast
    /// 重新编码，起点和终点精确到帧。
    case precise

    public var displayName: String {
        switch self {
        case .fast: return "快速（无损）"
        case .precise: return "精确"
        }
    }
}

/// 一个剪切区间（秒，相对文件开头）。
public struct CutRange: Sendable, Equatable, Hashable, Codable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

/// 精确模式用的视频编码器。
public enum CutEncoder: Sendable, Equatable {
    /// macOS：VideoToolbox 硬件编码（`-q:v 65`）。
    case videoToolbox
    /// 软件编码（Linux 测试）：libx264 / libx265。`lossless` 用于测试逐帧比对。
    case software(lossless: Bool)

    public static var platformDefault: CutEncoder {
        #if os(macOS)
        .videoToolbox
        #else
        .software(lossless: false)
        #endif
    }
}

/// 精确模式输出的视频编码。
public enum CutVideoCodec: String, Sendable, Equatable {
    case h264
    case hevc
}

public enum CutError: Error, Sendable, Equatable, LocalizedError {
    case noVideoStream
    case invalidRange(start: Double, end: Double)

    public var errorDescription: String? {
        switch self {
        case .noVideoStream:
            return "这个文件里没有视频画面，无法剪切。"
        case .invalidRange(let start, let end):
            return "剪切区间无效：起点 \(Timecode.format(start))，终点 \(Timecode.format(end))。终点必须晚于起点，并且在视频长度之内。"
        }
    }
}

/// 剪切的规划：容器、编码器和完整的 ffmpeg 参数。参数一律是数组，不经过 shell。
public enum CutPlanner {
    /// 精确模式 VideoToolbox 的质量参数（AGENTS.md 第 7 节）。
    public static let videoToolboxQuality = "65"
    public static let audioBitrate = "192k"

    // MARK: - 校验

    /// 把区间限制在视频长度内并检查（至少一帧）。
    public static func validate(_ range: CutRange, duration: Double?, minimumLength: Double = 0.001) throws -> CutRange {
        var r = range
        r.start = max(0, r.start)
        if let duration, duration > 0 { r.end = min(r.end, duration) }
        guard r.start.isFinite, r.end.isFinite, r.end - r.start >= minimumLength - 1e-9 else {
            throw CutError.invalidRange(start: range.start, end: range.end)
        }
        if let duration, duration > 0, r.start >= duration { throw CutError.invalidRange(start: range.start, end: range.end) }
        return r
    }

    // MARK: - 容器

    static let mp4VideoCodecs: Set<String> = ["h264", "hevc", "mpeg4", "av1"]
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac"]

    /// 快速模式的输出扩展名：音视频编码 MP4 能装下就是 `mp4`，否则保持原来的容器（例如 Opus 音频的 MKV → `mkv`）。
    /// 精确模式总是 `mp4`。
    public static func outputExtension(for info: MediaInfo, mode: CutMode, sourceExtension: String) -> String {
        guard mode == .fast else { return "mp4" }
        let videoOK = info.videoStream.map { mp4VideoCodecs.contains($0.codecName ?? "") } ?? false
        let audioOK = info.audioStreams.allSatisfy { mp4AudioCodecs.contains($0.codecName ?? "") }
        if videoOK, audioOK { return "mp4" }
        let ext = sourceExtension.lowercased()
        return ext.isEmpty ? "mkv" : ext
    }

    /// 扩展名对应的 ffmpeg 输出格式。
    public static func muxer(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "mp4", "m4v": return "mp4"
        case "mov": return "mov"
        case "mkv": return "matroska"
        case "webm": return "webm"
        case "avi": return "avi"
        case "ts", "mts", "m2ts": return "mpegts"
        default: return nil
        }
    }

    // MARK: - 快速模式

    /// `ffmpeg -ss S -i in -t D -map 0:v:0 -map 0:a? -c copy -avoid_negative_ts make_zero -movflags +faststart out`
    ///
    /// 输出从起点之前最近的关键帧开始，到终点结束。`-n`：输出已存在时失败，绝不覆盖。
    public static func fastArguments(input: URL, output: URL, range: CutRange, info: MediaInfo) -> [String] {
        let ext = output.pathExtension.lowercased()
        var args = ["-hide_banner", "-nostdin", "-n"] + FFmpegProgress.arguments
        args += ["-ss", seconds(range.start), "-i", input.path, "-t", seconds(range.duration)]
        args += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            if info.videoStream?.codecName == "hevc" { args += ["-tag:v", "hvc1"] }
            args += ["-movflags", "+faststart"]
        }
        if let muxer = muxer(forExtension: ext) { args += ["-f", muxer] }
        args.append(output.path)
        return args
    }

    /// 快速模式实际从哪里开始（起点之前最近的关键帧）。
    public static func fastActualStart(requested: Double, keyframeAtOrBefore keyframe: Double?) -> Double {
        guard let keyframe else { return 0 }
        return min(max(0, keyframe), requested)
    }

    // MARK: - 精确模式

    /// H.264 源 → H.264；HEVC 源 → HEVC；其他编码：8-bit SDR → H.264，10-bit 或 HDR → HEVC。
    public static func videoCodec(for video: MediaStream) -> CutVideoCodec {
        switch video.codecName {
        case "h264" where !video.isHighBitDepth && !video.isHDR: return .h264
        case "hevc": return .hevc
        default: return (video.isHighBitDepth || video.isHDR) ? .hevc : .h264
        }
    }

    /// 输出是否 10-bit（源是 10-bit 或 HDR）。
    public static func isTenBit(_ video: MediaStream) -> Bool {
        video.isHighBitDepth || video.isHDR
    }

    /// 精确模式的 ffmpeg 参数：从 S 解码，重新编码 D 秒，起点和终点精确到帧。
    public static func preciseArguments(
        input: URL, output: URL, range: CutRange, info: MediaInfo, encoder: CutEncoder
    ) throws -> [String] {
        guard let video = info.videoStream else { throw CutError.noVideoStream }
        let codec = videoCodec(for: video)
        let tenBit = isTenBit(video)

        var args = ["-hide_banner", "-nostdin", "-n"] + FFmpegProgress.arguments
        args += ["-ss", seconds(range.start), "-i", input.path, "-t", seconds(range.duration)]
        args += ["-map", "0:v:0", "-map", "0:a?"]
        args += videoEncoderArguments(codec: codec, tenBit: tenBit, encoder: encoder)
        args += colorArguments(video)
        if !info.audioStreams.isEmpty {
            args += ["-c:a", "aac", "-b:a", audioBitrate]
        }
        args += ["-sn", "-dn", "-movflags", "+faststart", "-f", "mp4", output.path]
        return args
    }

    static func videoEncoderArguments(codec: CutVideoCodec, tenBit: Bool, encoder: CutEncoder) -> [String] {
        switch (codec, encoder) {
        case (.h264, .videoToolbox):
            return ["-c:v", "h264_videotoolbox", "-q:v", videoToolboxQuality, "-allow_sw", "1", "-pix_fmt", "yuv420p"]
        case (.hevc, .videoToolbox):
            var a = ["-c:v", "hevc_videotoolbox", "-q:v", videoToolboxQuality, "-allow_sw", "1", "-tag:v", "hvc1"]
            a += tenBit ? ["-profile:v", "main10", "-pix_fmt", "p010le"] : ["-pix_fmt", "yuv420p"]
            return a
        case (.h264, .software(let lossless)):
            var a = ["-c:v", "libx264", "-preset", lossless ? "ultrafast" : "medium"]
            a += lossless ? ["-qp", "0"] : ["-crf", "18"]
            return a + ["-pix_fmt", "yuv420p"]
        case (.hevc, .software(let lossless)):
            let params = (lossless ? "lossless=1:" : "crf=20:") + "log-level=error"
            return ["-c:v", "libx265", "-preset", lossless ? "ultrafast" : "medium", "-x265-params", params,
                    "-tag:v", "hvc1", "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p"]
        }
    }

    /// 保留源文件的色彩参数（未知的值不写）。
    static func colorArguments(_ video: MediaStream) -> [String] {
        func known(_ v: String?) -> String? {
            guard let v, !v.isEmpty, v != "unknown", v != "reserved", v != "unspecified" else { return nil }
            return v
        }
        var a: [String] = []
        if let p = known(video.colorPrimaries) { a += ["-color_primaries", p] }
        if let t = known(video.colorTransfer) { a += ["-color_trc", t] }
        if let c = known(video.colorSpace) { a += ["-colorspace", c] }
        if let r = known(video.colorRange), r == "tv" || r == "pc" { a += ["-color_range", r] }
        return a
    }

    /// 导出前给用户的提示（例如 Dolby Vision 保留不了）。
    public static func warnings(for info: MediaInfo, mode: CutMode) -> [String] {
        guard mode == .precise, let video = info.videoStream else { return [] }
        var w: [String] = []
        if video.hasDolbyVision {
            w.append("这个视频带 Dolby Vision 元数据，精确模式重新编码后会丢失（仍然保留 HDR10/HLG 色彩信息）。需要保留时请用快速模式。")
        }
        return w
    }

    /// 编码器的说明（界面上显示）。
    public static func encoderDescription(for info: MediaInfo, encoder: CutEncoder) -> String? {
        guard let video = info.videoStream else { return nil }
        let codec = videoCodec(for: video)
        let name = codec == .hevc ? "HEVC" : "H.264"
        let depth = isTenBit(video) ? " 10-bit" : ""
        let hdr = video.isHDR ? " HDR" : ""
        let engine: String
        switch encoder {
        case .videoToolbox: engine = "VideoToolbox"
        case .software(let lossless): engine = lossless ? "软件编码（无损）" : "软件编码"
        }
        return "重新编码为 \(name)\(depth)\(hdr)（\(engine)），音频 AAC \(audioBitrate)"
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
