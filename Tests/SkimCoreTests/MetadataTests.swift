import Foundation
import XCTest
@testable import SkimCore

/// 视频信息和日期：解析、分组、参数生成、时区（不运行外部工具）。
final class MetadataTests: XCTestCase {
    let file = URL(fileURLWithPath: "/v/my clip.mp4")

    // MARK: - 读取和分组

    let sample = Data(#"""
    [{
      "SourceFile": "/v/my clip.mp4",
      "ExifTool:ExifToolVersion": 12.76,
      "System:FileName": "my clip.mp4",
      "System:FileModifyDate": "2026:10:17 08:24:58+00:00",
      "File:MIMEType": "video/mp4",
      "QuickTime:CompatibleBrands": ["isom","iso2","avc1"],
      "QuickTime:CreateDate": "2026:10:09 06:00:00+00:00",
      "QuickTime:Duration": "10.00 s",
      "QuickTime:TimeScale": 1000,
      "Track1:HandlerType": "Video Track",
      "Track1:ImageWidth": 640,
      "Track1:TrackCreateDate": "2026:10:09 06:00:00+00:00",
      "Track2:HandlerType": "Audio Track",
      "Track2:AudioChannels": 2,
      "Track2:MediaLanguageCode": "und",
      "Keys:CreationDate": "2026:10:09 14:00:00+08:00",
      "Keys:Title": "标题",
      "ItemList:Title": "旧标题",
      "ItemList:Comment": "注释",
      "Matroska:VideoFrameRate": 25
    }]
    """#.utf8)

    func testParseAndGroup() throws {
        let entries = MetadataReader.parse(sample)
        XCTAssertNil(entries.first { $0.family == "ExifTool" || $0.tag == "SourceFile" })
        XCTAssertEqual(entries.first { $0.id == "QuickTime:CompatibleBrands" }?.value, "isom, iso2, avc1")
        XCTAssertEqual(entries.first { $0.id == "Track1:ImageWidth" }?.value, "640")

        let sections = Dictionary(uniqueKeysWithValues: MetadataReader.sections(entries).map { ($0.group, Set($0.entries.map(\.id))) })
        XCTAssertEqual(sections[.file], ["System:FileName", "File:MIMEType"])
        XCTAssertEqual(sections[.date], [
            "System:FileModifyDate", "QuickTime:CreateDate", "Track1:TrackCreateDate", "Keys:CreationDate",
        ])
        XCTAssertEqual(sections[.video], ["Track1:HandlerType", "Track1:ImageWidth", "Matroska:VideoFrameRate"])
        XCTAssertEqual(sections[.audio], ["Track2:HandlerType", "Track2:AudioChannels", "Track2:MediaLanguageCode"])
        XCTAssertTrue(sections[.other]!.contains("QuickTime:Duration"))
        XCTAssertFalse(sections[.date]!.contains("QuickTime:TimeScale"), "TimeScale 不是日期")
        // 顺序：文件 / 视频 / 音频 / 日期 / 其他。
        XCTAssertEqual(MetadataReader.sections(entries).map(\.group), [.file, .video, .audio, .date, .other])
    }

    func testCommonFields() throws {
        let entries = MetadataReader.parse(sample)
        XCTAssertEqual(MetadataReader.first(entries, MetadataReader.titleKeys), "标题", "Keys:Title 优先")
        XCTAssertEqual(MetadataReader.first(entries, MetadataReader.descriptionKeys), "注释")
        let (date, hasZone) = try XCTUnwrap(MetadataReader.recordingDate(entries))
        XCTAssertTrue(hasZone)
        XCTAssertEqual(date.utcOffset, 8 * 3600)
        XCTAssertEqual(date.exifToolString, "2026:10:09 14:00:00+08:00")

        // 没有 Keys：用 UTC 的 CreateDate；1904 年（QuickTime 的“没有日期”）不算。
        let utcOnly = [MetadataEntry(family: "QuickTime", tag: "CreateDate", value: "2026:10:09 06:00:00+00:00")]
        XCTAssertEqual(MetadataReader.recordingDate(utcOnly)?.1, false)
        let zero = [MetadataEntry(family: "QuickTime", tag: "CreateDate", value: "1904:01:01 00:00:00+00:00")]
        XCTAssertNil(MetadataReader.recordingDate(zero))
        let mkv = [MetadataEntry(family: "Matroska", tag: "DateTimeOriginal", value: "2026:10:09 06:00:00Z")]
        XCTAssertEqual(MetadataReader.recordingDate(mkv)?.0.utcOffset, 0)
    }

    func testContainerKind() {
        XCTAssertEqual(ContainerKind.of(URL(fileURLWithPath: "/a.MOV")), .quickTime)
        XCTAssertEqual(ContainerKind.of(URL(fileURLWithPath: "/a.m4v")), .quickTime)
        XCTAssertEqual(ContainerKind.of(URL(fileURLWithPath: "/a.mkv")), .matroska)
        XCTAssertEqual(ContainerKind.of(URL(fileURLWithPath: "/a.webm")), .matroska)
        XCTAssertEqual(ContainerKind.of(URL(fileURLWithPath: "/a.avi")), .other)
        XCTAssertFalse(ContainerKind.other.canWriteEmbedded)
    }

    // MARK: - 参数

    func testQuickTimeDateArguments() throws {
        let date = try XCTUnwrap(QuickTimeDate.parse("2026:10:09 14:00:00+08:00"))
        XCTAssertEqual(MetadataEditor.quickTimeDateArguments(date, file: file), [
            "-m", "-q", "-overwrite_original_in_place", "-P", "-api", "QuickTimeUTC",
            "-QuickTime:CreateDate=2026:10:09 14:00:00+08:00", "-QuickTime:ModifyDate=2026:10:09 14:00:00+08:00",
            "-Track*Date=2026:10:09 14:00:00+08:00", "-Media*Date=2026:10:09 14:00:00+08:00",
            "-Keys:CreationDate=2026:10:09 14:00:00+08:00", "/v/my clip.mp4",
        ])
    }

    func testTextArguments() {
        let args = MetadataEditor.quickTimeTextArguments(title: "标题 \"x\"", description: nil, file: file)
        XCTAssertEqual(args, [
            "-m", "-q", "-overwrite_original_in_place", "-P",
            "-ItemList:Title=标题 \"x\"", "-Keys:Title=标题 \"x\"", "-UserData:Title=标题 \"x\"", "/v/my clip.mp4",
        ])
        let clear = MetadataEditor.quickTimeTextArguments(title: nil, description: "", file: file)
        XCTAssertTrue(clear.contains("-ItemList:Description="))
        XCTAssertTrue(clear.contains("-UserData:Comment="))

        let mkv = URL(fileURLWithPath: "/v/a.mkv")
        XCTAssertEqual(MetadataEditor.matroskaTextArguments(title: "T", tagsFile: nil, file: mkv),
                       ["/v/a.mkv", "--edit", "info", "--set", "title=T"])
        XCTAssertEqual(MetadataEditor.matroskaTextArguments(title: "", tagsFile: URL(fileURLWithPath: "/t/g.xml"), file: mkv),
                       ["/v/a.mkv", "--edit", "info", "--delete", "title", "--tags", "global:/t/g.xml"])
        let date = QuickTimeDate.parse("2026:10:09 14:00:00+08:00")!
        XCTAssertEqual(MetadataEditor.matroskaDateArguments(date, file: mkv),
                       ["/v/a.mkv", "--edit", "info", "--set", "date=2026-10-09T06:00:00Z"])
    }

    // MARK: - MKV 全局标签

    func testMatroskaGlobalTags() {
        let xml = Data("""
        \u{FEFF}<?xml version="1.0"?>
        <!-- <!DOCTYPE Tags SYSTEM "matroskatags.dtd"> -->
        <Tags>
          <Tag>
            <Targets />
            <Simple><Name>ENCODER</Name><String>Lavf60.16.100</String></Simple>
            <Simple><Name>COMMENT</Name><String>旧注释 &amp; 更多</String>
              <Simple><Name>NESTED</Name><String>忽略</String></Simple>
            </Simple>
          </Tag>
          <Tag>
            <Targets><TrackUID>4819540853157204586</TrackUID></Targets>
            <Simple><Name>DURATION</Name><String>00:00:08.000000000</String></Simple>
          </Tag>
        </Tags>
        """.utf8)
        var tags = MatroskaGlobalTags.parse(xml)
        XCTAssertEqual(tags.entries.map(\.name), ["ENCODER", "COMMENT"], "轨道标签和嵌套的子标签不算")
        XCTAssertEqual(tags.description, "旧注释 & 更多")

        tags.setDescription("新的 <描述> \"x\"")
        XCTAssertEqual(tags["DESCRIPTION"], "新的 <描述> \"x\"")
        XCTAssertEqual(tags["COMMENT"], "新的 <描述> \"x\"", "原来有 COMMENT 的也一起改")
        // 生成的 XML 再解析回来一样。
        XCTAssertEqual(MatroskaGlobalTags.parse(Data(tags.xml.utf8)), tags)
        XCTAssertTrue(tags.xml.contains("&lt;描述&gt; &quot;x&quot;"))

        tags.setDescription("")
        XCTAssertNil(tags["DESCRIPTION"])
        XCTAssertNil(tags["COMMENT"])
        XCTAssertEqual(tags.entries.map(\.name), ["ENCODER"])
    }

    // MARK: - 输入的时间和时区

    func testParseLocal() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let a = try XCTUnwrap(DateInput.parseLocal("2026-10-09 14:00", zone: shanghai))
        XCTAssertEqual(a.exifToolString, "2026:10:09 14:00:00+08:00")
        XCTAssertEqual(DateInput.parseLocal("2026:10:09 14:00:05", zone: shanghai)?.exifToolString, "2026:10:09 14:00:05+08:00")
        XCTAssertEqual(DateInput.parseLocal("2026-10-09T14:00:00", zone: shanghai)?.date, a.date)
        XCTAssertNil(DateInput.parseLocal("2026-02-30 10:00", zone: shanghai))
        XCTAssertNil(DateInput.parseLocal("2026-10-09 25:00", zone: shanghai))
        XCTAssertNil(DateInput.parseLocal("昨天", zone: shanghai))

        // 夏令时：同一个时区，夏天和冬天的偏移不同。
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(DateInput.parseLocal("2026-07-01 12:00", zone: ny)?.exifToolString, "2026:07:01 12:00:00-04:00")
        XCTAssertEqual(DateInput.parseLocal("2026-12-01 12:00", zone: ny)?.exifToolString, "2026:12:01 12:00:00-05:00")
    }

    func testParseZone() {
        XCTAssertEqual(DateInput.parseZone("Asia/Shanghai")?.identifier, "Asia/Shanghai")
        XCTAssertEqual(DateInput.parseZone("+08:00")?.secondsFromGMT(), 8 * 3600)
        XCTAssertEqual(DateInput.parseZone("+8")?.secondsFromGMT(), 8 * 3600)
        XCTAssertEqual(DateInput.parseZone("-05:30")?.secondsFromGMT(), -(5 * 3600 + 1800))
        XCTAssertEqual(DateInput.parseZone("UTC+9")?.secondsFromGMT(), 9 * 3600)
        XCTAssertEqual(DateInput.parseZone("UTC")?.secondsFromGMT(), 0)
        XCTAssertNil(DateInput.parseZone("+25:00"))
        XCTAssertNil(DateInput.parseZone("火星"))
        XCTAssertEqual(DateInput.offsetString(-(3 * 3600 + 1800)), "-03:30")
    }

    func testDisplayAndISO() throws {
        let d = try XCTUnwrap(QuickTimeDate.parse("2026:10:09 14:00:00+08:00"))
        XCTAssertEqual(DateInput.display(d), "2026-10-09 14:00:00 +08:00")
        XCTAssertEqual(d.iso8601UTC, "2026-10-09T06:00:00Z")
        XCTAssertEqual(QuickTimeDate.inZone(d.date, TimeZone(secondsFromGMT: -3600)!).exifToolString, "2026:10:09 05:00:00-01:00")
    }

    func testFileDatesEarliest() {
        let a = Date(timeIntervalSince1970: 1000)
        let b = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(FileDates(creation: b, modification: a).earliest, a)
        XCTAssertEqual(FileDates(creation: a, modification: b).earliest, a)
        XCTAssertEqual(FileDates(creation: nil, modification: b).earliest, b)
        XCTAssertNil(FileDates().earliest)
    }

    func testOperationNamesAndErrors() {
        XCTAssertEqual(DateOperation.embeddedToFile.displayName, "录制时间 → 文件日期")
        XCTAssertEqual(MetadataEditError.unsupportedContainer("avi").errorDescription, "这个格式（.avi）不能写入录制时间和标题，只能改文件日期。")
    }
}
