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

    public static func detect(_ file: URL, runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared) async throws -> String {
        try await runner.output(try locator.command(.uchardet, detectArguments(file)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
