import Foundation

/// 字幕格式。文字字幕可以转成 MP4 的 mov_text；图形字幕（SUP、IDX/SUB）只能放进 MKV。
public enum SubtitleFormat: String, Sendable, Equatable, CaseIterable, Codable {
    case srt
    case ass
    case ssa
    case vtt
    /// MP4 里的 3GPP 文字字幕（只会来自源视频里已有的轨道）。
    case movText = "mov_text"
    /// 蓝光 PGS（.sup）。
    case sup
    /// DVD 字幕（.idx + .sub）。
    case vobsub
    /// DVB 图形字幕（只会来自源视频）。
    case dvb

    /// 拖进来的文件按扩展名识别。`.sub` 只有旁边有同名 `.idx` 时才算 VobSub（输入用 `.idx`）。
    public static func detect(_ url: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> SubtitleFormat? {
        switch url.pathExtension.lowercased() {
        case "srt": return .srt
        case "ass": return .ass
        case "ssa": return .ssa
        case "vtt", "webvtt": return .vtt
        case "sup": return .sup
        case "idx": return .vobsub
        case "sub":
            return fileExists(url.deletingPathExtension().appendingPathExtension("idx")) ? .vobsub : nil
        default: return nil
        }
    }

    /// 源视频里已有的字幕流（ffprobe 的 codec_name）。
    public static func fromCodec(_ codec: String?) -> SubtitleFormat? {
        switch codec {
        case "subrip", "srt": return .srt
        case "ass": return .ass
        case "ssa": return .ssa
        case "webvtt": return .vtt
        case "mov_text": return .movText
        case "hdmv_pgs_subtitle": return .sup
        case "dvd_subtitle": return .vobsub
        case "dvb_subtitle": return .dvb
        default: return nil
        }
    }

    /// 字幕文件可以拖进来的扩展名。
    public static let fileExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "webvtt", "sup", "idx", "sub"]

    public static func isSubtitleFile(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// 文字字幕（可以检测编码、在 Swift 里平移、转成 mov_text）。
    public var isText: Bool {
        switch self {
        case .srt, .ass, .ssa, .vtt, .movText: return true
        case .sup, .vobsub, .dvb: return false
        }
    }

    /// 带样式（转成 MP4 的 mov_text 时样式会丢失）。
    public var hasStyles: Bool { self == .ass || self == .ssa }

    public var displayName: String {
        switch self {
        case .srt: return "SRT"
        case .ass: return "ASS"
        case .ssa: return "SSA"
        case .vtt: return "WebVTT"
        case .movText: return "MP4 文字"
        case .sup: return "SUP（图形）"
        case .vobsub: return "IDX/SUB（图形）"
        case .dvb: return "DVB（图形）"
        }
    }
}

/// 字幕的输出容器。
public enum SubtitleContainer: String, Sendable, Equatable, CaseIterable, Codable {
    /// 文字字幕转成 mov_text，ASS 样式会丢失。
    case mp4
    /// 保留原格式和样式；图形字幕只能用它。
    case mkv

    public var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mkv: return "MKV"
        }
    }
}

/// 常用的字幕语言（ISO 639-2）。默认 `chi`。
public enum SubtitleLanguages {
    public static let defaultCode = "chi"

    public static let common: [(code: String, name: String)] = [
        ("chi", "中文"), ("eng", "英语"), ("jpn", "日语"), ("kor", "韩语"),
        ("fre", "法语"), ("ger", "德语"), ("spa", "西班牙语"), ("rus", "俄语"),
        ("ita", "意大利语"), ("por", "葡萄牙语"), ("tha", "泰语"), ("vie", "越南语"),
        ("und", "未指定"),
    ]

    /// 用户输入的语言代码：去掉空格、转小写；空的或不是 2–3 个字母时返回 `und`。
    public static func normalize(_ code: String) -> String {
        let c = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard (2...3).contains(c.count), c.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "und" }
        return c
    }
}
