import Foundation

/// 用户输入的本地时间和时区。
public enum DateInput {
    /// 解析本地时间：`2026-10-09 14:00`、`2026-10-09 14:00:05`、`2026:10:09 14:00:00`、`2026-10-09T14:00:00`。
    /// 按 `zone` 换算成时间点，偏移按那一天算（夏令时也对）。
    public static func parseLocal(_ text: String, zone: TimeZone) -> QuickTimeDate? {
        let pattern = #"^(\d{4})[-:/](\d{1,2})[-:/](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$"#
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        func int(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: trimmed) else { return nil }
            return Int(trimmed[r])
        }
        guard let year = int(1), let month = int(2), let day = int(3), let hour = int(4), let minute = int(5),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60
        else { return nil }
        let second = int(6) ?? 0
        guard second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day  // 2 月 30 日之类的无效日期
        else { return nil }
        return QuickTimeDate.inZone(date, zone)
    }

    /// 时区：`Asia/Shanghai`、`UTC`、`+08:00`、`+8`、`-05:30`、`UTC+8`。
    public static func parseZone(_ text: String) -> TimeZone? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let zone = TimeZone(identifier: trimmed) { return zone }
        var s = trimmed.uppercased()
        if s.hasPrefix("UTC") || s.hasPrefix("GMT") { s = String(s.dropFirst(3)) }
        if s.isEmpty || s == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let parts = s.dropFirst().split(separator: ":")
        guard (1...2).contains(parts.count), let h = Int(parts[0]), h <= 14 else { return nil }
        let minutes = parts.count == 2 ? Int(parts[1]) : 0
        guard let minutes, minutes < 60 else { return nil }
        let seconds = (h * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// 显示用：`+08:00`。
    public static func offsetString(_ seconds: Int) -> String {
        let a = abs(seconds)
        return (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", a / 3600, (a % 3600) / 60)
    }

    /// 显示用：`2026-10-09 14:00:00 +08:00`。
    public static func display(_ date: QuickTimeDate) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: date.utcOffset) ?? TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date.date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0) + offsetString(date.utcOffset)
    }
}
