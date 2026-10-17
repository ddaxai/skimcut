import Foundation
import XCTest
@testable import SkimCore

/// 真正运行 exiftool / mkvpropedit / mkvextract 的信息和日期测试。
final class MetadataIntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var editor: MetadataEditor { MetadataEditor(runner: runner) }

    /// 复制一份测试素材（原素材不改）；`ext` 不同时用 ffmpeg 转封装。
    private func copy(_ name: String, as newName: String) async throws -> URL {
        let media = try TestSupport.testMedia()
        let source = media.appendingPathComponent(name)
        let target = dir.appendingPathComponent(newName)
        if source.pathExtension == target.pathExtension {
            try FileManager.default.copyItem(at: source, to: target)
        } else {
            _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
                "-hide_banner", "-nostdin", "-v", "error", "-i", source.path, "-c", "copy", target.path,
            ]))
        }
        return target
    }

    private func read(_ url: URL) async throws -> MediaMetadata {
        try await MetadataReader.read(url, runner: runner)
    }

    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    // MARK: - 读取

    func testReadGroupsRealFile() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        let mp4 = try await copy("loud_medium.mp4", as: "a b.mp4")
        let m = try await read(mp4)
        XCTAssertEqual(m.kind, .quickTime)
        XCTAssertNil(m.recordingDate, "ffmpeg 生成的文件没有日期（1904 年）")
        let groups = Dictionary(uniqueKeysWithValues: m.sections.map { ($0.group, $0.entries) })
        XCTAssertTrue(groups[.file]?.contains { $0.tag == "FileName" && $0.value == "a b.mp4" } ?? false)
        XCTAssertTrue(groups[.video]?.contains { $0.tag == "ImageWidth" && $0.value == "640" } ?? false)
        XCTAssertTrue(groups[.audio]?.contains { $0.tag == "AudioChannels" } ?? false)
        XCTAssertTrue(groups[.date]?.contains { $0.id == "QuickTime:CreateDate" } ?? false)
        XCTAssertNotNil(m.fileDates.modification)
    }

    // MARK: - MP4 / MOV

    /// 原来没有日期的 MP4 / MOV：全部日期设为同一个时间。UTC 字段、带时区的 Keys:CreationDate、文件日期都写好并核对。
    func testSetAllOnQuickTimeAddsDates() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        for name in ["clip.mp4", "clip.mov"] {
            let url = try await copy("loud_medium.mp4", as: name)
            let date = try XCTUnwrap(DateInput.parseLocal("2026-10-09 14:00", zone: shanghai))
            let change = try await editor.apply(.setAll(date), to: url)
            XCTAssertEqual(change.embedded, date)
            XCTAssertNil(change.note)

            let m = try await read(url)
            XCTAssertEqual(m.recordingDate?.exifToolString, "2026:10:09 14:00:00+08:00", name)
            XCTAssertTrue(m.recordingDateHasTimeZone)
            XCTAssertEqual(m.entries.first { $0.id == "QuickTime:CreateDate" }?.value, "2026:10:09 06:00:00+00:00", "UTC")
            let trackDates = m.entries.filter { $0.family.hasPrefix("Track") && $0.tag.hasSuffix("Date") }
            XCTAssertEqual(trackDates.count, 8, "两条轨道 × Track/Media × Create/Modify")
            XCTAssertTrue(trackDates.allSatisfy { $0.value == "2026:10:09 06:00:00+00:00" }, "\(trackDates)")
            XCTAssertEqual(try XCTUnwrap(m.fileDates.modification).timeIntervalSince(date.date), 0, accuracy: 1)
            if FileDates.canWriteCreation {
                XCTAssertEqual(try XCTUnwrap(m.fileDates.creation).timeIntervalSince(date.date), 0, accuracy: 1)
            }
        }
    }

    /// 只改录制时间时，文件的修改日期保持不变。
    func testSetEmbeddedKeepsFileDates() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        let url = try await copy("loud_medium.mp4", as: "keep.mp4")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileDates(creation: old, modification: old).write(to: url)
        let date = try XCTUnwrap(DateInput.parseLocal("2025-01-02 03:04:05", zone: TimeZone(identifier: "America/New_York")!))
        _ = try await editor.apply(.setEmbedded(date), to: url)
        let m = try await read(url)
        XCTAssertEqual(m.recordingDate?.exifToolString, "2025:01:02 03:04:05-05:00")
        XCTAssertEqual(try XCTUnwrap(m.fileDates.modification).timeIntervalSince(old), 0, accuracy: 1)
    }

    func testSyncBetweenEmbeddedAndFileDates() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        let url = try await copy("loud_medium.mp4", as: "sync.mp4")
        // 没有录制时间时不能同步到文件日期。
        do {
            _ = try await editor.apply(.embeddedToFile, to: url)
            XCTFail("应该报没有录制时间")
        } catch {
            XCTAssertEqual(error as? MetadataEditError, .noEmbeddedDate)
        }

        // 文件日期 → 录制时间（按指定的时区写）。
        let fileDate = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
        try FileDates(creation: fileDate, modification: fileDate).write(to: url)
        let change = try await editor.apply(.fileToEmbedded(shanghai), to: url)
        XCTAssertEqual(change.embedded?.exifToolString, "2023:11:15 06:13:20+08:00")
        // 内部日期 → 文件日期。
        try FileDates(creation: nil, modification: Date()).write(to: url)
        _ = try await editor.apply(.embeddedToFile, to: url)
        XCTAssertEqual(try XCTUnwrap(FileDates.read(url).modification).timeIntervalSince(fileDate), 0, accuracy: 1)
    }

    func testTitleAndDescriptionOnQuickTime() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        let url = try await copy("loud_medium.mp4", as: "text.mov")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileDates(creation: nil, modification: old).write(to: url)
        try await editor.setText(title: "标题 \"引号\" & 符号", description: "第一行\n第二行", on: url)
        var m = try await read(url)
        XCTAssertEqual(m.title, "标题 \"引号\" & 符号")
        XCTAssertEqual(m.description, "第一行\n第二行")
        XCTAssertEqual(try XCTUnwrap(m.fileDates.modification).timeIntervalSince(old), 0, accuracy: 1, "改标题不改文件日期")

        // 只改描述，标题不变；空字符串删除。
        try await editor.setText(title: nil, description: "", on: url)
        m = try await read(url)
        XCTAssertEqual(m.title, "标题 \"引号\" & 符号")
        XCTAssertNil(m.description)
    }

    // MARK: - MKV

    func testMatroskaDatesTitleAndDescription() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        _ = try TestSupport.requireTool(.mkvpropedit)
        _ = try TestSupport.requireTool(.mkvextract)
        let url = try await copy("sample.mkv", as: "片段 1.mkv")
        let date = try XCTUnwrap(DateInput.parseLocal("2026-10-09 14:00", zone: shanghai))
        _ = try await editor.apply(.setAll(date), to: url)
        try await editor.setText(title: "中文 标题", description: "描述 <x> & \"y\"", on: url)

        let m = try await read(url)
        XCTAssertEqual(m.kind, .matroska)
        XCTAssertEqual(try XCTUnwrap(m.recordingDate).date.timeIntervalSince(date.date), 0, accuracy: 1)
        XCTAssertEqual(m.title, "中文 标题")
        XCTAssertEqual(m.description, "描述 <x> & \"y\"")
        XCTAssertEqual(try XCTUnwrap(m.fileDates.modification).timeIntervalSince(date.date), 0, accuracy: 1)

        // 原有的全局标签（ENCODER）和轨道标签都还在。
        let tags = try await editor.matroskaGlobalTags(url)
        XCTAssertNotNil(tags["ENCODER"])
        let all = try await runner.output(try ToolLocator.shared.command(.mkvextract, [url.path, "tags", "-"]))
        XCTAssertEqual(all.components(separatedBy: "<TrackUID>").count - 1, 2, "两条轨道的标签")

        // 只改标题时描述不变。
        try await editor.setText(title: "新标题", description: nil, on: url)
        let again = try await read(url)
        XCTAssertEqual(again.title, "新标题")
        XCTAssertEqual(again.description, "描述 <x> & \"y\"")
    }

    // MARK: - 其他格式

    func testOtherFormatsOnlyChangeFileDates() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        let url = try await copy("sample_mpeg4.avi", as: "old.avi")
        let date = try XCTUnwrap(DateInput.parseLocal("2020-05-06 07:08:09", zone: shanghai))
        let change = try await editor.apply(.setAll(date), to: url)
        XCTAssertNil(change.embedded)
        XCTAssertNotNil(change.note)
        XCTAssertEqual(try XCTUnwrap(FileDates.read(url).modification).timeIntervalSince(date.date), 0, accuracy: 1)
        do {
            _ = try await editor.apply(.setEmbedded(date), to: url)
            XCTFail("AVI 不能写内部日期")
        } catch {
            XCTAssertEqual(error as? MetadataEditError, .unsupportedContainer("avi"))
        }
    }

    /// 批量：同一个操作用在多个文件上。
    func testBatchSetAll() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        _ = try TestSupport.requireTool(.mkvpropedit)
        let files = [
            try await copy("loud_quiet.mp4", as: "1.mp4"),
            try await copy("loud_loud.mp4", as: "2.mov"),
            try await copy("sample.mkv", as: "3.mkv"),
        ]
        let date = try XCTUnwrap(DateInput.parseLocal("2026-01-01 00:00", zone: shanghai))
        for url in files {
            _ = try await editor.apply(.setAll(date), to: url)
            let m = try await read(url)
            XCTAssertEqual(try XCTUnwrap(m.recordingDate, url.lastPathComponent).date.timeIntervalSince(date.date), 0, accuracy: 1)
        }
    }

    // MARK: - 新文件自动复制元数据（M2 已经做了，这里补标题）

    func testCutCopiesTitleAndDescription() async throws {
        _ = try TestSupport.requireTool(.exiftool)
        let source = try await copy("h264_gop4.mp4", as: "source.mp4")
        try await editor.setText(title: "原标题", description: "原描述", on: source)
        let exporter = CutExporter(runner: runner)
        let info = try await MediaInfo.probe(source, runner: runner)
        let plan = try await exporter.plan(
            source: source, info: info, range: CutRange(start: 4, end: 6),
            options: CutOptions(mode: .fast, outputDirectory: dir))
        let result = try await exporter.export(plan)
        let m = try await read(result.output)
        XCTAssertEqual(m.title, "原标题")
        XCTAssertEqual(m.description, "原描述")
    }
}
