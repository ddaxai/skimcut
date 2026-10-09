import Foundation

/// SkimCore 的版本号（CLI 和 App 都显示它）。
public enum SkimCoreInfo {
    public static let version = "0.0.1"
}

/// SkimCut 依赖的外部命令行工具。
public enum Tool: String, CaseIterable, Sendable, Codable {
    case ffmpeg
    case ffprobe
    case ffmpegNormalize = "ffmpeg-normalize"
    case exiftool
    case mkvpropedit
    case uchardet
    case iconv

    /// 可执行文件名。
    public var executableName: String { rawValue }

    /// 用来打印版本号的参数。
    public var versionArguments: [String] {
        switch self {
        case .ffmpeg, .ffprobe: return ["-hide_banner", "-version"]
        case .exiftool: return ["-ver"]
        case .ffmpegNormalize, .mkvpropedit, .uchardet, .iconv: return ["--version"]
        }
    }

    /// 缺少这个工具时，告诉用户怎么安装。
    public var installHint: String {
        #if os(macOS)
        switch self {
        case .ffmpeg, .ffprobe: return "brew install ffmpeg"
        case .ffmpegNormalize: return "brew install uv && uv tool install ffmpeg-normalize"
        case .exiftool: return "brew install exiftool"
        case .mkvpropedit: return "brew install mkvtoolnix"
        case .uchardet: return "brew install uchardet"
        case .iconv: return "系统自带（/usr/bin/iconv）"
        }
        #else
        switch self {
        case .ffmpeg, .ffprobe: return "apt-get install -y ffmpeg"
        case .ffmpegNormalize: return "uv tool install ffmpeg-normalize"
        case .exiftool: return "apt-get install -y libimage-exiftool-perl"
        case .mkvpropedit: return "apt-get install -y mkvtoolnix"
        case .uchardet: return "apt-get install -y uchardet"
        case .iconv: return "系统自带（glibc）"
        }
        #endif
    }

    /// 从 `--version` 一类的输出里取出版本号，例如
    /// `ffmpeg version 6.1.1-3ubuntu5 Copyright …` → `6.1.1-3ubuntu5`，
    /// `mkvpropedit v82.0 ('…') 64-bit` → `82.0`。
    public static func parseVersion(_ output: String) -> String? {
        let pattern = #"(?<![\w.])v?(\d+(?:\.\d+)+(?:-[0-9A-Za-z.~+]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let r = Range(match.range(at: 1), in: output)
        else { return nil }
        return String(output[r])
    }
}
