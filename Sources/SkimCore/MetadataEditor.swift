import Foundation

/// 日期的快捷操作（可以对多个文件做）。
public enum DateOperation: Sendable, Equatable {
    /// 全部日期（内部录制时间 + 文件的创建 / 修改日期）设为同一个时间。
    case setAll(QuickTimeDate)
    /// 只改内部录制时间（原来没有时会添加）。
    case setEmbedded(QuickTimeDate)
    /// 只改文件的创建 / 修改日期。
    case setFile(Date)
    /// 内部录制时间 → 文件日期。
    case embeddedToFile
    /// 文件日期（创建和修改中较早的一个）→ 内部录制时间，按这个时区写。
    case fileToEmbedded(TimeZone)

    public var displayName: String {
        switch self {
        case .setAll: return "全部日期设为同一个时间"
        case .setEmbedded: return "设置录制时间"
        case .setFile: return "设置文件日期"
        case .embeddedToFile: return "录制时间 → 文件日期"
        case .fileToEmbedded: return "文件日期 → 录制时间"
        }
    }
}

/// 一次修改实际写入了什么。
public struct DateChange: Sendable, Equatable {
    public var url: URL
    /// 写入的录制时间（没有写时为 nil，例如这个格式不能写内部日期）。
    public var embedded: QuickTimeDate?
    /// 写入的文件日期（没有写时为 nil）。
    public var file: Date?
    /// 给用户看的补充说明。
    public var note: String?
}

public enum MetadataEditError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedContainer(String)
    case noEmbeddedDate
    case noFileDate

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let ext):
            return "这个格式（.\(ext)）不能写入录制时间和标题，只能改文件日期。"
        case .noEmbeddedDate:
            return "视频里没有录制时间，没法同步到文件日期。"
        case .noFileDate:
            return "读不到文件日期。"
        }
    }
}

/// 修改原文件的元数据：录制时间、标题、描述、文件日期。
///
/// - MP4 / MOV：ExifTool。`QuickTime:CreateDate`、`ModifyDate`、`Track*Date`、`Media*Date` 是 UTC，
///   `Keys:CreationDate` 是本地时间并带时区（“照片” App 用它）。用 `-overwrite_original_in_place`，
///   不换文件，Finder 标签等扩展属性保留。
/// - MKV：mkvpropedit（日期只有 UTC；描述写在全局标签里，其他全局标签原样保留）。
/// - 只改内部数据时，文件的创建 / 修改日期保持不变（写完后恢复）。
/// - 写入后重新读取并核对，不一致就报错。
public struct MetadataEditor: Sendable {
    public var runner: ToolRunner
    public var locator: ToolLocator

    public init(runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared) {
        self.runner = runner
        self.locator = locator
    }

    // MARK: - 参数

    static let quickTimeDateTags = ["QuickTime:CreateDate", "QuickTime:ModifyDate", "Track*Date", "Media*Date"]

    /// `exiftool -api QuickTimeUTC -overwrite_original_in_place -P "-QuickTime:CreateDate=V" … "-Keys:CreationDate=V" 文件`
    public static func quickTimeDateArguments(_ date: QuickTimeDate, file: URL) -> [String] {
        let v = date.exifToolString
        return ["-m", "-q", "-overwrite_original_in_place", "-P", "-api", "QuickTimeUTC"]
            + quickTimeDateTags.map { "-\($0)=\(v)" }
            + ["-Keys:CreationDate=\(v)", file.path]
    }

    /// 标题和描述；nil 表示不改，空字符串表示删除。几个常见的位置都写，免得不同的播放器显示不一样。
    public static func quickTimeTextArguments(title: String?, description: String?, file: URL) -> [String] {
        var args = ["-m", "-q", "-overwrite_original_in_place", "-P"]
        if let title {
            args += ["ItemList:Title", "Keys:Title", "UserData:Title"].map { "-\($0)=\(title)" }
        }
        if let description {
            args += ["ItemList:Description", "ItemList:Comment", "Keys:Description", "UserData:Description", "UserData:Comment"]
                .map { "-\($0)=\(description)" }
        }
        args.append(file.path)
        return args
    }

    /// `mkvpropedit 文件 --edit info --set date=2026-10-09T06:00:00Z`
    public static func matroskaDateArguments(_ date: QuickTimeDate, file: URL) -> [String] {
        [file.path, "--edit", "info", "--set", "date=\(date.iso8601UTC)"]
    }

    /// 标题（`--edit info --set title=…`，空字符串删除）和描述（`--tags global:XML`）。
    public static func matroskaTextArguments(title: String?, tagsFile: URL?, file: URL) -> [String] {
        var args = [file.path]
        if let title {
            args += ["--edit", "info"] + (title.isEmpty ? ["--delete", "title"] : ["--set", "title=\(title)"])
        }
        if let tagsFile {
            args += ["--tags", "global:\(tagsFile.path)"]
        }
        return args
    }

    // MARK: - 读取

    /// `mkvextract 文件 tags -`，只取全局标签。
    public func matroskaGlobalTags(_ url: URL) async throws -> MatroskaGlobalTags {
        let result = try await runner.run(try locator.command(.mkvextract, [url.path, "tags", "-"]))
        return MatroskaGlobalTags.parse(result.stdout)
    }

    private func readEntries(_ url: URL, _ tags: [String]) async throws -> [MetadataEntry] {
        let args = ["-j", "-G1", "-a", "-s", "-api", "QuickTimeUTC"] + tags + [url.path]
        return MetadataReader.parse(try await runner.run(try locator.command(.exiftool, args)).stdout)
    }

    // MARK: - 录制时间

    /// 写入录制时间（原来没有时添加），文件日期保持不变，然后核对。
    public func setRecordingDate(_ date: QuickTimeDate, on url: URL) async throws {
        let kind = ContainerKind.of(url)
        guard kind.canWriteEmbedded else { throw MetadataEditError.unsupportedContainer(url.pathExtension.lowercased()) }
        try await preservingFileDates(url) {
            switch kind {
            case .quickTime:
                _ = try await runner.run(try locator.command(.exiftool, Self.quickTimeDateArguments(date, file: url)))
            case .matroska:
                _ = try await runner.run(try locator.command(.mkvpropedit, Self.matroskaDateArguments(date, file: url)))
            case .other:
                break
            }
        }
        try await verifyRecordingDate(date, on: url, kind: kind)
    }

    private func verifyRecordingDate(_ expected: QuickTimeDate, on url: URL, kind: ContainerKind) async throws {
        func fail(_ actual: String) -> MetadataError {
            .verificationFailed(expected: expected.exifToolString, actual: actual)
        }
        func same(_ value: String) -> Bool {
            guard let d = QuickTimeDate.parse(value) else { return false }
            return abs(d.date.timeIntervalSince(expected.date)) <= 1
        }
        switch kind {
        case .quickTime:
            let entries = try await readEntries(url, ["-time:all"])
            let utc = entries.filter {
                ($0.family == "QuickTime" || $0.family.hasPrefix("Track"))
                    && ["CreateDate", "ModifyDate", "TrackCreateDate", "TrackModifyDate", "MediaCreateDate", "MediaModifyDate"].contains($0.tag)
            }
            guard utc.contains(where: { $0.id == "QuickTime:CreateDate" }) else { throw fail("没有 QuickTime:CreateDate") }
            if let wrong = utc.first(where: { !same($0.value) }) { throw fail("\(wrong.id) = \(wrong.value)") }
            guard let keys = entries.first(where: { $0.id == "Keys:CreationDate" }) else { throw fail("没有 Keys:CreationDate") }
            guard same(keys.value), QuickTimeDate.parse(keys.value)?.utcOffset == expected.utcOffset else {
                throw fail("Keys:CreationDate = \(keys.value)")
            }
        case .matroska:
            let entries = try await readEntries(url, ["-Matroska:DateTimeOriginal"])
            guard let value = entries.first(where: { $0.tag == "DateTimeOriginal" })?.value else { throw fail("没有日期") }
            guard same(value) else { throw fail(value) }
        case .other:
            break
        }
    }

    // MARK: - 标题和描述

    /// 修改标题和描述（nil 不改，空字符串删除），文件日期保持不变，然后核对。
    public func setText(title: String?, description: String?, on url: URL) async throws {
        guard title != nil || description != nil else { return }
        let kind = ContainerKind.of(url)
        guard kind.canWriteEmbedded else { throw MetadataEditError.unsupportedContainer(url.pathExtension.lowercased()) }
        try await preservingFileDates(url) {
            switch kind {
            case .quickTime:
                _ = try await runner.run(try locator.command(
                    .exiftool, Self.quickTimeTextArguments(title: title, description: description, file: url)))
            case .matroska:
                var tagsFile: URL?
                if let description {
                    var tags = try await matroskaGlobalTags(url)
                    tags.setDescription(description)
                    let xml = FileManager.default.temporaryDirectory.appendingPathComponent("skimcut-tags-\(UUID().uuidString).xml")
                    try Data(tags.xml.utf8).write(to: xml)
                    tagsFile = xml
                }
                defer { if let tagsFile { try? FileManager.default.removeItem(at: tagsFile) } }
                _ = try await runner.run(try locator.command(
                    .mkvpropedit, Self.matroskaTextArguments(title: title, tagsFile: tagsFile, file: url)))
            case .other:
                break
            }
        }
        let after = try await MetadataReader.read(url, runner: runner, locator: locator)
        func normalized(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if let title, normalized(after.title) != normalized(title) {
            throw MetadataError.verificationFailed(expected: "标题“\(title)”", actual: "“\(after.title ?? "")”")
        }
        if let description, normalized(after.description) != normalized(description) {
            throw MetadataError.verificationFailed(expected: "描述“\(description)”", actual: "“\(after.description ?? "")”")
        }
    }

    // MARK: - 文件日期

    /// 设置文件的创建日期（只在 macOS 上）和修改日期，然后核对。
    public func setFileDates(_ date: Date, on url: URL) throws {
        try FileDates(creation: date, modification: date).write(to: url)
        let after = try FileDates.read(url)
        func same(_ d: Date?) -> Bool { d.map { abs($0.timeIntervalSince(date)) <= 1 } ?? false }
        guard same(after.modification), !FileDates.canWriteCreation || same(after.creation) else {
            let expected = QuickTimeDate.inZone(date, .current).exifToolString
            let actual = [after.creation, after.modification].map { $0.map { QuickTimeDate.inZone($0, .current).exifToolString } ?? "无" }
            throw MetadataError.verificationFailed(
                expected: "文件日期 \(expected)", actual: "创建 \(actual[0])，修改 \(actual[1])")
        }
    }

    // MARK: - 快捷操作

    public func apply(_ operation: DateOperation, to url: URL) async throws -> DateChange {
        let kind = ContainerKind.of(url)
        switch operation {
        case .setAll(let date):
            var note: String?
            var embedded: QuickTimeDate?
            if kind.canWriteEmbedded {
                try await setRecordingDate(date, on: url)
                embedded = date
            } else {
                note = MetadataEditError.unsupportedContainer(url.pathExtension.lowercased()).errorDescription
            }
            try setFileDates(date.date, on: url)
            return DateChange(url: url, embedded: embedded, file: date.date, note: note)
        case .setEmbedded(let date):
            try await setRecordingDate(date, on: url)
            return DateChange(url: url, embedded: date, file: nil)
        case .setFile(let date):
            try setFileDates(date, on: url)
            return DateChange(url: url, embedded: nil, file: date)
        case .embeddedToFile:
            let metadata = try await MetadataReader.read(url, runner: runner, locator: locator)
            guard let recording = metadata.recordingDate else { throw MetadataEditError.noEmbeddedDate }
            try setFileDates(recording.date, on: url)
            return DateChange(url: url, embedded: nil, file: recording.date)
        case .fileToEmbedded(let zone):
            guard let date = try FileDates.read(url).earliest else { throw MetadataEditError.noFileDate }
            let recording = QuickTimeDate.inZone(date, zone)
            try await setRecordingDate(recording, on: url)
            return DateChange(url: url, embedded: recording, file: nil)
        }
    }

    /// 运行 `body`，之后把文件的创建 / 修改日期恢复成原来的样子（写内部数据会改变它们）。
    private func preservingFileDates(_ url: URL, _ body: () async throws -> Void) async throws {
        let before = try? FileDates.read(url)
        try await body()
        if let before { try? before.write(to: url) }
    }
}

extension QuickTimeDate {
    /// 某个时区里的时间：偏移按那一天算（夏令时也对）。
    public static func inZone(_ date: Date, _ zone: TimeZone) -> QuickTimeDate {
        QuickTimeDate(date: date, utcOffset: zone.secondsFromGMT(for: date))
    }

    /// `2026-10-09T06:00:00Z`（mkvpropedit 用）。
    public var iso8601UTC: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded()))
    }
}
