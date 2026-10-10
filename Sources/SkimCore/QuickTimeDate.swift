import Foundation

/// ExifTool 的日期：`2026:10:09 14:00:00+08:00`（秒可以带小数，时区可以是 `Z` 或没有）。
public struct QuickTimeDate: Sendable, Equatable {
    /// 绝对时间点。
    public var date: Date
    /// 显示和写入时用的时区偏移（秒）。
    public var utcOffset: Int

    public init(date: Date, utcOffset: Int) {
        self.date = date
        self.utcOffset = utcOffset
    }

    /// 解析；没有时区时按 `defaultOffset`（默认 UTC）。全零日期（`0000:00:00 …`）和 1904 年（QuickTime 的“没有日期”）返回 nil。
    public static func parse(_ text: String, defaultOffset: Int = 0) -> QuickTimeDate? {
        let pattern = #"^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: trimmed) else { return nil }
            return String(trimmed[r])
        }
        guard let year = Int(group(1) ?? ""), let month = Int(group(2) ?? ""), let day = Int(group(3) ?? ""),
              let hour = Int(group(4) ?? ""), let minute = Int(group(5) ?? ""), let second = Int(group(6) ?? "")
        else { return nil }
        guard year > 1904, (1...12).contains(month), (1...31).contains(day) else { return nil }

        var offset = defaultOffset
        if let tz = group(8) {
            if tz == "Z" {
                offset = 0
            } else {
                let sign = tz.hasPrefix("-") ? -1 : 1
                let parts = tz.dropFirst().split(separator: ":")
                guard parts.count == 2, let h = Int(parts[0]), let mm = Int(parts[1]) else { return nil }
                offset = sign * (h * 3600 + mm * 60)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard var date = calendar.date(from: components) else { return nil }
        if let frac = group(7), let f = Double("0" + frac) { date.addTimeInterval(f) }
        return QuickTimeDate(date: date, utcOffset: offset)
    }

    /// `2026:10:09 14:00:00+08:00`（QuickTime 日期只到秒，四舍五入）。
    public var exifToolString: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: utcOffset) ?? TimeZone(secondsFromGMT: 0)!
        let rounded = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
        let sign = utcOffset < 0 ? "-" : "+"
        let a = abs(utcOffset)
        let local = String(
            format: "%04d:%02d:%02d %02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return local + sign + String(format: "%02d:%02d", a / 3600, (a % 3600) / 60)
    }

    public func adding(seconds: Double) -> QuickTimeDate {
        QuickTimeDate(date: date.addingTimeInterval(seconds), utcOffset: utcOffset)
    }
}
