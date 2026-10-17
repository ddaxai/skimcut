import Foundation

/// 内部元数据能用什么工具写。
public enum ContainerKind: Sendable, Equatable {
    /// MP4 / MOV / M4V：ExifTool。
    case quickTime
    /// MKV / WebM：mkvpropedit（ExifTool 不能写 MKV）。
    case matroska
    /// 其他格式：只能改文件日期。
    case other

    public static func of(_ url: URL) -> ContainerKind {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return .quickTime
        case "mkv", "webm", "mka": return .matroska
        default: return .other
        }
    }

    public var canWriteEmbedded: Bool { self != .other }
}

/// 信息分组。
public enum MetadataGroup: String, CaseIterable, Sendable {
    case file, video, audio, date, other

    public var displayName: String {
        switch self {
        case .file: return "文件"
        case .video: return "视频"
        case .audio: return "音频"
        case .date: return "日期"
        case .other: return "其他"
        }
    }
}

/// ExifTool 的一项：`Track1:ImageWidth = 640`。
public struct MetadataEntry: Sendable, Equatable, Identifiable {
    /// `-G1` 的组名，例如 `QuickTime`、`Track1`、`Keys`、`System`。
    public var family: String
    public var tag: String
    public var value: String

    public var id: String { "\(family):\(tag)" }

    public init(family: String, tag: String, value: String) {
        self.family = family
        self.tag = tag
        self.value = value
    }
}

public struct MetadataSection: Sendable, Equatable, Identifiable {
    public var group: MetadataGroup
    public var entries: [MetadataEntry]
    public var id: MetadataGroup { group }
}

/// 文件系统的日期。
public struct FileDates: Sendable, Equatable {
    /// 创建日期（只有 macOS 能改；Linux 上可能读不到）。
    public var creation: Date?
    public var modification: Date?

    public init(creation: Date? = nil, modification: Date? = nil) {
        self.creation = creation
        self.modification = modification
    }

    /// 两个里较早的一个（从相机导入时，修改日期常常保留了真实的录制时间，创建日期是导入的时间）。
    public var earliest: Date? {
        [creation, modification].compactMap { $0 }.min()
    }

    public static func read(_ url: URL) throws -> FileDates {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileDates(creation: attrs[.creationDate] as? Date, modification: attrs[.modificationDate] as? Date)
    }

    /// 设置（nil 的不改）。创建日期只在 macOS 上能改，其他系统上忽略。
    public func write(to url: URL) throws {
        var attrs: [FileAttributeKey: Any] = [:]
        if let modification { attrs[.modificationDate] = modification }
        #if os(macOS)
        if let creation { attrs[.creationDate] = creation }
        #endif
        guard !attrs.isEmpty else { return }
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    /// 这个系统能不能改创建日期。
    public static var canWriteCreation: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// 一个文件的全部信息（ExifTool）和常用的几项。
public struct MediaMetadata: Sendable, Equatable {
    public var url: URL
    public var kind: ContainerKind
    public var entries: [MetadataEntry]
    /// 录制时间：`Keys:CreationDate`（带时区）→ `QuickTime:CreateDate`（UTC）→ MKV 的 `DateTimeOriginal`（UTC）。
    public var recordingDate: QuickTimeDate?
    /// 录制时间有没有时区（`Keys:CreationDate`）。没有时区的是 UTC，“照片” App 可能显示错误。
    public var recordingDateHasTimeZone: Bool
    public var title: String?
    public var description: String?
    public var fileDates: FileDates

    public var sections: [MetadataSection] { MetadataReader.sections(entries) }
}

/// 读取并整理 ExifTool 的输出。
public enum MetadataReader {
    /// `exiftool -j -G1 -a -s -api QuickTimeUTC 文件`
    public static func arguments(_ url: URL) -> [String] {
        ["-j", "-G1", "-a", "-s", "-api", "QuickTimeUTC", url.path]
    }

    /// 把 JSON 展开成一项一项（数组用逗号连起来）。
    public static func parse(_ data: Data) -> [MetadataEntry] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let object = array.first else {
            return []
        }
        var entries: [MetadataEntry] = []
        for (key, raw) in object {
            guard key != "SourceFile" else { continue }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let (family, tag) = parts.count == 2 ? (parts[0], parts[1]) : ("", parts[0])
            guard family != "ExifTool" else { continue }
            entries.append(MetadataEntry(family: family, tag: tag, value: describe(raw)))
        }
        // JSONSerialization 不保证顺序：按组、再按名字排。
        return entries.sorted { ($0.family, $0.tag) < ($1.family, $1.tag) }
    }

    private static func describe(_ raw: Any) -> String {
        switch raw {
        case let s as String: return s
        case let a as [Any]: return a.map(describe).joined(separator: ", ")
        case let n as NSNumber: return n.stringValue
        default: return "\(raw)"
        }
    }

    /// 是不是日期：名字以 Date 结尾，或者包含 DateTime。
    static func isDate(_ tag: String) -> Bool {
        tag.hasSuffix("Date") || tag.contains("DateTime")
    }

    /// 分组：日期 → 文件（System / File）→ 按轨道的类型分视频 / 音频 → 按名字猜 → 其他。
    public static func group(of entry: MetadataEntry, trackHandlers: [String: MetadataGroup]) -> MetadataGroup {
        if isDate(entry.tag) { return .date }
        if ["System", "File", "MacOS"].contains(entry.family) { return .file }
        if let g = trackHandlers[entry.family] { return g }
        let tag = entry.tag
        if tag.hasPrefix("Audio") || tag == "Balance" { return .audio }
        if tag.hasPrefix("Video") || tag.hasPrefix("Image") || tag.hasPrefix("Display") || tag.contains("FrameRate")
            || tag == "CompressorID" || tag == "CompressorName" || tag == "BitDepth" || tag.hasPrefix("Color") {
            return .video
        }
        return .other
    }

    public static func sections(_ entries: [MetadataEntry]) -> [MetadataSection] {
        // TrackN 的 HandlerType 决定这条轨道是视频还是音频。
        var handlers: [String: MetadataGroup] = [:]
        for e in entries where e.tag == "HandlerType" && e.family.hasPrefix("Track") {
            let v = e.value.lowercased()
            if v.contains("video") { handlers[e.family] = .video } else if v.contains("audio") { handlers[e.family] = .audio }
        }
        var grouped: [MetadataGroup: [MetadataEntry]] = [:]
        for e in entries {
            grouped[group(of: e, trackHandlers: handlers), default: []].append(e)
        }
        return MetadataGroup.allCases.compactMap { g in
            grouped[g].map { MetadataSection(group: g, entries: $0) }
        }
    }

    /// 取第一个有值的标签。
    static func first(_ entries: [MetadataEntry], _ keys: [String]) -> String? {
        for key in keys {
            if let e = entries.first(where: { $0.id == key }), !e.value.trimmingCharacters(in: .whitespaces).isEmpty {
                return e.value
            }
        }
        return nil
    }

    static let titleKeys = ["Keys:Title", "ItemList:Title", "UserData:Title", "QuickTime:Title", "Matroska:Title"]
    static let descriptionKeys = [
        "Keys:Description", "ItemList:Description", "UserData:Description", "ItemList:Comment", "UserData:Comment",
        "Keys:Comment",
    ]

    /// 录制时间。1904 年 / 全零的“没有日期”已经由 `QuickTimeDate.parse` 排除。
    static func recordingDate(_ entries: [MetadataEntry]) -> (QuickTimeDate, Bool)? {
        if let keys = first(entries, ["Keys:CreationDate"]).flatMap({ QuickTimeDate.parse($0) }) {
            return (keys, true)
        }
        if let utc = first(entries, ["QuickTime:CreateDate", "Matroska:DateTimeOriginal"]).flatMap({ QuickTimeDate.parse($0) }) {
            return (utc, false)
        }
        return nil
    }

    /// 读取一个文件。MKV 的描述在全局标签里（ExifTool 不显示），用 mkvextract 读。
    public static func read(
        _ url: URL, runner: ToolRunner = ToolRunner(), locator: ToolLocator = .shared
    ) async throws -> MediaMetadata {
        let result = try await runner.run(try locator.command(.exiftool, arguments(url)))
        let entries = parse(result.stdout)
        let kind = ContainerKind.of(url)
        var description = first(entries, descriptionKeys)
        if kind == .matroska, locator.locate(.mkvextract) != nil {
            let tags = try await MetadataEditor(runner: runner, locator: locator).matroskaGlobalTags(url)
            description = tags.description
        }
        let recording = recordingDate(entries)
        return MediaMetadata(
            url: url, kind: kind, entries: entries,
            recordingDate: recording?.0, recordingDateHasTimeZone: recording?.1 ?? false,
            title: first(entries, titleKeys), description: description,
            fileDates: (try? FileDates.read(url)) ?? FileDates())
    }
}
