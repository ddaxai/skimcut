import Foundation

/// 剪切时平移文字字幕的时间：减去剪切起点，去掉完全在区间外的字幕，跨过起点的从 0 开始，
/// 跨过终点的截到终点。
///
/// SRT / VTT 按 AGENTS.md 在 Swift 里处理。ASS / SSA 原计划交给 ffmpeg，但已验证 ffmpeg 的 `-ss` 和
/// `-itsoffset` 会把跨过起点的事件写成 `0:00:-1.00` 这种无效时间，所以也在 Swift 里处理：
/// 只改 `Dialogue` / `Comment` 行的 Start / End，样式和其他内容原样保留。
public enum SubtitleShifter {
    /// - Parameters:
    ///   - offset: 减去的秒数（剪切的实际起点）。
    ///   - duration: 剪出来的长度；nil 表示不截尾。
    public static func shift(_ text: String, format: SubtitleFormat, by offset: Double, duration: Double? = nil) -> String {
        switch format {
        case .srt: return shiftCues(text, by: offset, duration: duration, style: .srt)
        case .vtt: return shiftCues(text, by: offset, duration: duration, style: .vtt)
        case .ass, .ssa: return shiftASS(text, by: offset, duration: duration)
        case .movText, .sup, .vobsub, .dvb: return text
        }
    }

    /// 平移后的区间；完全在外面时返回 nil。
    static func shiftedInterval(_ start: Double, _ end: Double, by offset: Double, duration: Double?) -> (Double, Double)? {
        var s = start - offset
        var e = end - offset
        guard e > 0.0005 else { return nil }
        if let duration {
            guard s < duration - 0.0005 else { return nil }
            e = min(e, duration)
        }
        s = max(0, s)
        guard e > s else { return nil }
        return (s, e)
    }

    // MARK: - SRT / VTT

    enum CueStyle { case srt, vtt }

    static func shiftCues(_ text: String, by offset: Double, duration: Double?, style: CueStyle) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) }
            .filter { !$0.isEmpty }
        var output: [String] = []
        var number = 1
        for block in blocks {
            var lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                // VTT 的头部、NOTE、STYLE 等原样保留；SRT 里没有时间行的块丢掉。
                if style == .vtt { output.append(block) }
                continue
            }
            guard let (start, end, rest) = parseTimingLine(lines[timingIndex]),
                  let (s, e) = shiftedInterval(start, end, by: offset, duration: duration)
            else { continue }
            lines[timingIndex] = formatCueTime(s, style) + " --> " + formatCueTime(e, style) + rest
            if style == .srt {
                // 重新编号：时间行之前的序号行换成新的序号。
                let body = Array(lines[timingIndex...])
                lines = [String(number)] + body
                number += 1
            }
            output.append(lines.joined(separator: "\n"))
        }
        return output.joined(separator: "\n\n") + "\n"
    }

    /// `00:01:02,500 --> 00:01:04,000 X1:...` → (62.5, 64.0, " X1:...")
    static func parseTimingLine(_ line: String) -> (Double, Double, String)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let rightParts = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let rightTime = rightParts.first,
              let start = parseCueTime(left), let end = parseCueTime(String(rightTime))
        else { return nil }
        let rest = rightParts.count > 1 ? " " + rightParts[1] : ""
        return (start, end, rest)
    }

    /// `HH:MM:SS,mmm`、`HH:MM:SS.mmm`、`MM:SS.mmm`
    static func parseCueTime(_ s: String) -> Double? {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), let sec = Double(parts[parts.count - 1]) else { return nil }
        let ints = parts.dropLast().compactMap { Int($0) }
        guard ints.count == parts.count - 1 else { return nil }
        return ints.reduce(0) { $0 * 60 + Double($1) } * 60 + sec
    }

    static func formatCueTime(_ t: Double, _ style: CueStyle) -> String {
        let ms = Int64((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms / 60_000) % 60
        let s = (ms / 1000) % 60
        let f = ms % 1000
        let sep = style == .srt ? "," : "."
        return String(format: "%02lld:%02lld:%02lld", h, m, s) + sep + String(format: "%03lld", f)
    }

    // MARK: - ASS / SSA

    static func shiftASS(_ text: String, by offset: Double, duration: Double?) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline)
        var inEvents = false
        // 默认的 [Events] 字段顺序。
        var startIndex = 1
        var endIndex = 2
        var fieldCount = 10
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                output.append(line)
                continue
            }
            if inEvents, trimmed.lowercased().hasPrefix("format:") {
                let fields = trimmed.dropFirst("format:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                startIndex = fields.firstIndex(of: "start") ?? 1
                endIndex = fields.firstIndex(of: "end") ?? 2
                fieldCount = fields.count
                output.append(line)
                continue
            }
            guard inEvents, let colon = trimmed.firstIndex(of: ":"),
                  ["dialogue", "comment"].contains(trimmed[..<colon].lowercased())
            else {
                output.append(line)
                continue
            }
            let head = String(trimmed[...colon])
            let body = trimmed[trimmed.index(after: colon)...].drop { $0 == " " }
            // 最后一个字段（Text）里可能有逗号，只切前面的字段。
            var fields = body.split(separator: ",", maxSplits: max(fieldCount - 1, 1), omittingEmptySubsequences: false).map(String.init)
            guard fields.count > max(startIndex, endIndex),
                  let start = parseASSTime(fields[startIndex]), let end = parseASSTime(fields[endIndex]),
                  let (s, e) = shiftedInterval(start, end, by: offset, duration: duration)
            else { continue }
            fields[startIndex] = formatASSTime(s)
            fields[endIndex] = formatASSTime(e)
            output.append(head + " " + fields.joined(separator: ","))
        }
        return output.joined(separator: newline)
    }

    /// `H:MM:SS.cc`
    static func parseASSTime(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let sec = Double(parts[2]) else { return nil }
        return Double(h) * 3600 + Double(m) * 60 + sec
    }

    static func formatASSTime(_ t: Double) -> String {
        let cs = Int64((max(0, t) * 100).rounded())
        let h = cs / 360_000
        let m = (cs / 6000) % 60
        let s = (cs / 100) % 60
        let f = cs % 100
        return String(format: "%lld:%02lld:%02lld.%02lld", h, m, s, f)
    }
}
