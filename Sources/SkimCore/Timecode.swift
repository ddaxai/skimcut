import Foundation

/// 时间的显示和解析。界面上统一显示为 `HH:MM:SS.mmm`。
public enum Timecode {
    /// 秒 → `HH:MM:SS.mmm`，例如 83.456 → `00:01:23.456`。
    /// 先四舍五入到毫秒再拆分，避免出现 `00:00:59.1000`。负数显示为 `-` 开头。
    public static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--:--.---" }
        let sign = seconds < 0 ? "-" : ""
        let totalMillis = Int64((abs(seconds) * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return sign + pad(h, 2) + ":" + pad(m, 2) + ":" + pad(s, 2) + "." + pad(ms, 3)
    }

    /// 解析用户输入的时间，支持：
    /// - `83.456`、`83`（秒）
    /// - `1:23.456`（分:秒）
    /// - `00:01:23.456`（时:分:秒）
    /// 小数点也可以写成逗号（SRT 习惯）。前后空格忽略。不接受负数。
    /// 有多个冒号字段时，除第一个字段外分和秒必须小于 60。
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        // 只有最后一个字段可以带小数。
        for (i, part) in parts.enumerated() {
            let allowDot = i == parts.count - 1
            guard isNumber(part, allowDot: allowDot) else { return nil }
        }
        guard let last = Double(parts[parts.count - 1]) else { return nil }
        if parts.count == 1 { return last }

        let ints = parts.dropLast().compactMap { Int($0) }
        guard ints.count == parts.count - 1 else { return nil }
        guard last < 60 else { return nil }
        if parts.count == 2 {
            return Double(ints[0]) * 60 + last
        }
        guard ints[1] < 60 else { return nil }
        return Double(ints[0]) * 3600 + Double(ints[1]) * 60 + last
    }

    private static func isNumber(_ s: String, allowDot: Bool) -> Bool {
        guard !s.isEmpty else { return false }
        var dots = 0
        var digits = 0
        for c in s {
            if c == "." {
                dots += 1
            } else if c.isASCII, c.isNumber {
                digits += 1
            } else {
                return false
            }
        }
        if dots > (allowDot ? 1 : 0) { return false }
        return digits > 0
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
