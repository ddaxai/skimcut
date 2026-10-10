import Foundation

/// 录制时间：`QuickTime:CreateDate`（UTC）和 `Keys:CreationDate`（本地时间 + 时区，“照片” App 用它）。
public struct RecordingDates: Sendable, Equatable {
    public var createDate: QuickTimeDate?
    public var keysCreationDate: QuickTimeDate?

    public init(createDate: QuickTimeDate? = nil, keysCreationDate: QuickTimeDate? = nil) {
        self.createDate = createDate
        self.keysCreationDate = keysCreationDate
    }

    public var isEmpty: Bool { createDate == nil && keysCreationDate == nil }

    /// 两个时间点都平移 `seconds` 秒（时区不变）。
    public func shifted(by seconds: Double) -> RecordingDates {
        RecordingDates(
            createDate: createDate?.adding(seconds: seconds),
            keysCreationDate: keysCreationDate?.adding(seconds: seconds))
    }

    /// 时间点是否一致（QuickTime 日期只到秒，容忍 1 秒）。
    public func matches(_ other: RecordingDates) -> Bool {
        func same(_ a: QuickTimeDate?, _ b: QuickTimeDate?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return abs(a.date.timeIntervalSince(b.date)) <= 1
            default: return false
            }
        }
        return same(createDate, other.createDate) && same(keysCreationDate, other.keysCreationDate)
    }
}

public enum MetadataError: Error, Sendable, Equatable, LocalizedError {
    case verificationFailed(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let expected, let actual):
            return "写入元数据后重新读取，结果不一致。应该是：\(expected)；实际是：\(actual)"
        }
    }
}

/// 用 ExifTool 把源文件的元数据复制到新文件（只适用于 MP4/MOV），并可以把录制时间平移剪切起点。
/// 写入后重新读取并核对，不一致就报错。
public struct MetadataCopier: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared) {
        self.runner = runner
        self.locator = locator
    }

    /// ExifTool 能写的 QuickTime 容器。
    public static func supports(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// `exiftool -tagsFromFile src -all:all dst`
    public static func copyArguments(from source: URL, to destination: URL) -> [String] {
        ["-m", "-q", "-overwrite_original", "-api", "QuickTimeUTC",
         "-tagsFromFile", source.path, "-all:all", destination.path]
    }

    public static func readDatesArguments(_ file: URL) -> [String] {
        ["-j", "-G1", "-a", "-s", "-api", "QuickTimeUTC", "-QuickTime:CreateDate", "-Keys:CreationDate", file.path]
    }

    /// 解析 `exiftool -j -G1` 的输出。
    public static func parseDates(_ data: Data) -> RecordingDates {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first
        else { return RecordingDates() }
        return RecordingDates(
            createDate: (first["QuickTime:CreateDate"] as? String).flatMap { QuickTimeDate.parse($0) },
            keysCreationDate: (first["Keys:CreationDate"] as? String).flatMap { QuickTimeDate.parse($0) })
    }

    /// 写入录制时间的参数：UTC 字段（CreateDate、ModifyDate、Track*Date、Media*Date）和带时区的 Keys:CreationDate。
    /// 值都带时区，ExifTool（`-api QuickTimeUTC`）会换算成 UTC 写进 QuickTime 字段。
    /// 两个时间都没有时返回 nil。
    public static func writeDatesArguments(_ dates: RecordingDates, file: URL) -> [String]? {
        guard let utc = dates.createDate ?? dates.keysCreationDate else { return nil }
        // QuickTime 字段用 Keys 的时区书写（时间点相同，只是写法），没有 Keys 时用原来的偏移。
        let offset = dates.keysCreationDate?.utcOffset ?? utc.utcOffset
        let v = QuickTimeDate(date: utc.date, utcOffset: offset).exifToolString
        var args = ["-m", "-q", "-overwrite_original", "-api", "QuickTimeUTC",
                    "-QuickTime:CreateDate=\(v)", "-QuickTime:ModifyDate=\(v)", "-Track*Date=\(v)", "-Media*Date=\(v)"]
        if let keys = dates.keysCreationDate {
            args.append("-Keys:CreationDate=\(keys.exifToolString)")
        }
        args.append(file.path)
        return args
    }

    public func readDates(_ file: URL) async throws -> RecordingDates {
        let result = try await runner.run(try locator.command(.exiftool, Self.readDatesArguments(file)))
        return Self.parseDates(result.stdout)
    }

    /// 复制元数据；`shiftDatesBy` 不为 nil 时把录制时间平移这么多秒。返回写入后的录制时间。
    @discardableResult
    public func copy(from source: URL, to destination: URL, shiftDatesBy shift: Double?) async throws -> RecordingDates {
        _ = try await runner.run(try locator.command(.exiftool, Self.copyArguments(from: source, to: destination)))
        let sourceDates = try await readDates(source)
        var expected = sourceDates
        if let shift, shift != 0, !sourceDates.isEmpty {
            expected = sourceDates.shifted(by: shift)
            if let args = Self.writeDatesArguments(expected, file: destination) {
                _ = try await runner.run(try locator.command(.exiftool, args))
            }
        }
        let actual = try await readDates(destination)
        guard actual.matches(expected) else {
            throw MetadataError.verificationFailed(expected: describe(expected), actual: describe(actual))
        }
        return actual
    }

    private func describe(_ d: RecordingDates) -> String {
        let create = d.createDate?.exifToolString ?? "无"
        let keys = d.keysCreationDate?.exifToolString ?? "无"
        return "CreateDate \(create)，Keys:CreationDate \(keys)"
    }
}
