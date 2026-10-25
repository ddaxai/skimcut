import Foundation

/// 字幕文件的文字编码：先用 uchardet 检测（中文字幕常见 GBK / GB18030 / Big5 / UTF-16），
/// 再用 iconv 转成 UTF-8 临时文件。
public enum SubtitleEncoding {
    /// uchardet 的结果是否已经是 UTF-8（ASCII 是 UTF-8 的子集）。
    public static func isUTF8(_ charset: String) -> Bool {
        let c = charset.uppercased()
        return c == "UTF-8" || c == "ASCII" || c == "US-ASCII"
    }

    /// uchardet 没认出来。
    public static func isUnknown(_ charset: String) -> Bool {
        let c = charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return c.isEmpty || c == "unknown" || c.hasPrefix("unknown")
    }

    /// 给用户看的名字。
    public static func displayName(_ charset: String) -> String {
        if isUnknown(charset) { return "未知编码" }
        switch charset.uppercased() {
        case "ASCII", "US-ASCII": return "ASCII"
        case "GB18030": return "GB18030（GBK）"
        default: return charset.uppercased()
        }
    }

    public static func detectArguments(_ file: URL) -> [String] { [file.path] }

    public static func convertArguments(_ file: URL, from charset: String) -> [String] {
        ["-f", charset, "-t", "UTF-8", file.path]
    }

    /// 手动选择编码时的选项（uchardet 认错时用）。
    public static let choices: [(code: String, name: String)] = [
        ("UTF-8", "UTF-8"),
        ("GB18030", "简体中文 GB18030（GBK）"),
        ("BIG5", "繁体中文 Big5"),
        ("UTF-16", "UTF-16"),
        ("SHIFT_JIS", "日文 Shift_JIS"),
        ("EUC-KR", "韩文 EUC-KR"),
    ]

    /// 单字节的旧编码（WINDOWS-125x、ISO-8859-x、KOI8 等）。内容很少的中文字幕常常被 uchardet 认成这些。
    static func isSingleByteLegacy(_ charset: String) -> Bool {
        let c = charset.uppercased()
        return ["WINDOWS-125", "CP125", "ISO-8859", "KOI8", "MAC-", "MACCYRILLIC", "IBM", "CP8", "TIS-620", "VISCII"]
            .contains { c.hasPrefix($0) }
    }

    /// 非 ASCII 字符里中文（汉字、中文标点、全角符号）的比例；非 ASCII 字符太少时为 0。
    public static func chineseRatio(_ text: String) -> Double {
        var nonASCII = 0
        var chinese = 0
        for scalar in text.unicodeScalars where scalar.value > 0x7F {
            nonASCII += 1
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3000...0x303F, 0xFF00...0xFFEF, 0x2010...0x206F:
                chinese += 1
            default:
                break
            }
        }
        return nonASCII >= 2 ? Double(chinese) / Double(nonASCII) : 0
    }

    /// 检测编码。uchardet 的结果是单字节旧编码、但按 GB18030 读出来几乎全是中文时，当作 GB18030
    /// （已验证：只有两行“第一句 test”的 GBK 字幕会被认成 WINDOWS-1256）。真的阿拉伯文、俄文等字幕
    /// 里单个字节后面常跟着空格，在 GB18030 里不合法，iconv 会拒绝，所以不会被误改。
    public static func detect(_ file: URL, runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared) async throws -> String {
        let raw = try await runner.output(try locator.command(.uchardet, detectArguments(file)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSingleByteLegacy(raw) else { return raw }
        if let text = try? await readUTF8(file, charset: "GB18030", runner: runner, locator: locator),
           chineseRatio(text) >= 0.9 {
            return "GB18030"
        }
        return raw
    }

    /// 读出 UTF-8 文本：已经是 UTF-8 的直接读，否则用 iconv 转换。去掉开头的 BOM。
    public static func readUTF8(
        _ file: URL, charset: String, runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared
    ) async throws -> String {
        let data: Data
        if isUTF8(charset) || isUnknown(charset) {
            data = try Data(contentsOf: file)
        } else {
            data = try await runner.run(try locator.command(.iconv, convertArguments(file, from: charset))).stdout
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }
}
