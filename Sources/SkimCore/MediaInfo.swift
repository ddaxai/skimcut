import Foundation

/// ffprobe 读出的一条流（只保留需要的字段）。
public struct MediaStream: Sendable, Equatable {
    public var index: Int
    /// `video` / `audio` / `subtitle` / `data` / `attachment`
    public var codecType: String
    public var codecName: String?
    /// 例如 `hvc1`、`hev1`、`avc1`；MKV 里通常是 `[0][0][0][0]`。
    public var codecTagString: String?
    public var profile: String?
    public var width: Int?
    public var height: Int?
    public var pixelFormat: String?
    /// 平均帧率（`avg_frame_rate`，无效时退回 `r_frame_rate`）。
    public var frameRate: Double?
    public var duration: Double?
    public var colorTransfer: String?
    public var colorPrimaries: String?
    /// 封面图（MP3/MP4 里常见），不算真正的视频流。
    public var isAttachedPicture: Bool
    public var language: String?
    /// 例如 `bt709`、`bt2020nc`。
    public var colorSpace: String?
    /// `tv`（有限范围）或 `pc`（全范围）。
    public var colorRange: String?
    /// 带 Dolby Vision 配置（重新编码时保留不了）。
    public var hasDolbyVision: Bool

    public init(
        index: Int, codecType: String, codecName: String? = nil, codecTagString: String? = nil,
        profile: String? = nil, width: Int? = nil, height: Int? = nil, pixelFormat: String? = nil,
        frameRate: Double? = nil, duration: Double? = nil, colorTransfer: String? = nil,
        colorPrimaries: String? = nil, isAttachedPicture: Bool = false, language: String? = nil,
        colorSpace: String? = nil, colorRange: String? = nil, hasDolbyVision: Bool = false
    ) {
        self.index = index
        self.codecType = codecType
        self.codecName = codecName
        self.codecTagString = codecTagString
        self.profile = profile
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.frameRate = frameRate
        self.duration = duration
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.isAttachedPicture = isAttachedPicture
        self.language = language
        self.colorSpace = colorSpace
        self.colorRange = colorRange
        self.hasDolbyVision = hasDolbyVision
    }

    public var isVideo: Bool { codecType == "video" && !isAttachedPicture }
    public var isAudio: Bool { codecType == "audio" }

    /// 10-bit 及以上（看像素格式名里的位深）。
    public var isHighBitDepth: Bool {
        guard let fmt = pixelFormat else { return false }
        // yuv420p10le、yuv422p12be、p010le、p016le 等；注意 yuv410p 是 8-bit。
        return fmt.range(of: #"(p0(10|12|16)|(9|10|12|14|16)(le|be))$"#, options: .regularExpression) != nil
    }

    /// HDR 传输特性：PQ（HDR10 / Dolby Vision）或 HLG。
    public var isHDR: Bool {
        guard let trc = colorTransfer else { return false }
        return trc == "smpte2084" || trc == "arib-std-b67"
    }
}

/// ffprobe `-show_format -show_streams` 的结果。
public struct MediaInfo: Sendable, Equatable {
    /// 例如 `mov,mp4,m4a,3gp,3g2,mj2`、`matroska,webm`、`avi`。
    public var formatName: String
    /// 容器的起始时间（ffprobe `format.start_time`）。ffmpeg 的 `-ss` 是相对这个时间的，
    /// 所以 ffprobe 读到的绝对时间要减去它才能和 `-ss` 对上。
    public var startTime: Double
    public var duration: Double?
    public var streams: [MediaStream]

    public init(formatName: String, duration: Double?, streams: [MediaStream], startTime: Double = 0) {
        self.formatName = formatName
        self.startTime = startTime
        self.duration = duration
        self.streams = streams
    }

    /// 第一条真正的视频流（跳过封面图）。
    public var videoStream: MediaStream? { streams.first(where: \.isVideo) }
    public var audioStreams: [MediaStream] { streams.filter(\.isAudio) }

    /// 总时长：优先容器时长，没有时取各条流里最长的。
    public var bestDuration: Double? {
        if let d = duration, d > 0 { return d }
        return streams.compactMap(\.duration).filter { $0 > 0 }.max()
    }

    /// 容器是 MP4 / MOV 家族。
    public var isQuickTimeFamily: Bool {
        formatName.split(separator: ",").contains { ["mov", "mp4", "m4a"].contains(String($0)) }
    }

    // MARK: - ffprobe

    /// `ffprobe -v error -print_format json -show_format -show_streams <file>`
    public static func probeArguments(for url: URL) -> [String] {
        ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
    }

    public static func probe(
        _ url: URL, runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared
    ) async throws -> MediaInfo {
        let command = try locator.command(.ffprobe, probeArguments(for: url))
        let result = try await runner.run(command)
        do {
            return try parse(result.stdout)
        } catch {
            throw ToolError.nonZeroExit(result)
        }
    }

    public enum ParseError: Error, Equatable {
        case notJSON
    }

    /// 解析 ffprobe 的 JSON 输出。
    public static func parse(_ data: Data) throws -> MediaInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = (root["streams"] as? [[String: Any]] ?? []).map(parseStream)
        return MediaInfo(
            formatName: format["format_name"] as? String ?? "",
            duration: number(format["duration"]),
            streams: streams,
            startTime: number(format["start_time"]) ?? 0
        )
    }

    private static func parseStream(_ s: [String: Any]) -> MediaStream {
        let disposition = s["disposition"] as? [String: Any] ?? [:]
        let tags = s["tags"] as? [String: Any] ?? [:]
        let rate = parseRate(s["avg_frame_rate"] as? String) ?? parseRate(s["r_frame_rate"] as? String)
        return MediaStream(
            index: int(s["index"]) ?? 0,
            codecType: s["codec_type"] as? String ?? "",
            codecName: s["codec_name"] as? String,
            codecTagString: s["codec_tag_string"] as? String,
            profile: s["profile"] as? String,
            width: int(s["width"]),
            height: int(s["height"]),
            pixelFormat: s["pix_fmt"] as? String,
            frameRate: rate,
            duration: number(s["duration"]),
            colorTransfer: s["color_transfer"] as? String,
            colorPrimaries: s["color_primaries"] as? String,
            isAttachedPicture: int(disposition["attached_pic"]) == 1,
            language: tags["language"] as? String,
            colorSpace: s["color_space"] as? String,
            colorRange: s["color_range"] as? String,
            hasDolbyVision: hasDolbyVision(s)
        )
    }

    /// Dolby Vision：流的 side data 里有 DOVI 配置记录，或者编码标签是 dvh1 / dvhe / dva1 / dvav。
    private static func hasDolbyVision(_ s: [String: Any]) -> Bool {
        if let tag = s["codec_tag_string"] as? String, ["dvh1", "dvhe", "dva1", "dvav"].contains(tag) {
            return true
        }
        let sideData = s["side_data_list"] as? [[String: Any]] ?? []
        return sideData.contains { ($0["side_data_type"] as? String)?.contains("DOVI") == true }
    }

    /// `30000/1001` → 29.97；`0/0` → nil。
    public static func parseRate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 {
            return n / d
        }
        if parts.count == 1, let v = Double(parts[0]), v > 0 { return v }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
