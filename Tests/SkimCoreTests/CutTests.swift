import Foundation
import XCTest
@testable import SkimCore

final class OutputNamingTests: XCTestCase {
    func testTimeTag() {
        XCTAssertEqual(OutputNaming.timeTag(83.456), "01m23.456s")
        XCTAssertEqual(OutputNaming.timeTag(95.4564), "01m35.456s")
        XCTAssertEqual(OutputNaming.timeTag(0), "00m00.000s")
        XCTAssertEqual(OutputNaming.timeTag(59.9996), "01m00.000s")
        XCTAssertEqual(OutputNaming.timeTag(3723.5), "1h02m03.500s")
    }

    func testCutFileName() {
        let src = URL(fileURLWithPath: "/Movies/我的 视频.MOV")
        XCTAssertEqual(
            OutputNaming.cutFileName(source: src, range: CutRange(start: 83.456, end: 95.456), extension: "mp4"),
            "我的 视频_cut_01m23.456s-01m35.456s.mp4")
    }

    func testUniqueURLNeverOverwrites() {
        let base = URL(fileURLWithPath: "/x/a_cut.mp4")
        let taken: Set<String> = ["/x/a_cut.mp4", "/x/a_cut_2.mp4"]
        XCTAssertEqual(OutputNaming.uniqueURL(base) { taken.contains($0.path) }.path, "/x/a_cut_3.mp4")
        XCTAssertEqual(OutputNaming.uniqueURL(base) { _ in false }, base)
    }
}

final class QuickTimeDateTests: XCTestCase {
    func testParseWithZoneAndFormat() throws {
        let d = try XCTUnwrap(QuickTimeDate.parse("2026:10:09 14:00:00+08:00"))
        XCTAssertEqual(d.utcOffset, 8 * 3600)
        XCTAssertEqual(d.date.timeIntervalSince1970, 1_791_525_600)  // 2026-10-09 06:00:00 UTC
        XCTAssertEqual(d.exifToolString, "2026:10:09 14:00:00+08:00")
        let z = try XCTUnwrap(QuickTimeDate.parse("2026:10:09 06:00:00Z"))
        XCTAssertEqual(z.date, d.date)
        let neg = try XCTUnwrap(QuickTimeDate.parse("2026:10:08 23:30:00-06:30"))
        XCTAssertEqual(neg.date, d.date)
        XCTAssertEqual(neg.exifToolString, "2026:10:08 23:30:00-06:30")
        // 没有时区：按 UTC。
        XCTAssertEqual(QuickTimeDate.parse("2026:10:09 06:00:00")?.date, d.date)
        XCTAssertEqual(QuickTimeDate.parse("2026:10:09 06:00:00.250+00:00")?.date.timeIntervalSince1970, 1_791_525_600.25)
    }

    func testEmptyDatesAreNil() {
        XCTAssertNil(QuickTimeDate.parse("0000:00:00 00:00:00"))
        XCTAssertNil(QuickTimeDate.parse("1904:01:01 00:00:00+00:00"))
        XCTAssertNil(QuickTimeDate.parse("garbage"))
    }

    func testShiftKeepsZoneAndRounds() throws {
        let d = try XCTUnwrap(QuickTimeDate.parse("2026:12:31 23:59:58+08:00"))
        XCTAssertEqual(d.adding(seconds: 5.5).exifToolString, "2027:01:01 00:00:04+08:00")
        XCTAssertEqual(d.adding(seconds: 1.4).exifToolString, "2026:12:31 23:59:59+08:00")
    }
}

final class MetadataCopierTests: XCTestCase {
    func testArguments() {
        let src = URL(fileURLWithPath: "/a/源 'x'.mov")
        let dst = URL(fileURLWithPath: "/b/out.mp4")
        XCTAssertEqual(MetadataCopier.copyArguments(from: src, to: dst), [
            "-m", "-q", "-overwrite_original", "-api", "QuickTimeUTC", "-tagsFromFile", src.path, "-all:all", dst.path,
        ])
        XCTAssertTrue(MetadataCopier.supports(dst))
        XCTAssertTrue(MetadataCopier.supports(src))
        XCTAssertFalse(MetadataCopier.supports(URL(fileURLWithPath: "/a.mkv")))
    }

    func testWriteDatesUsesKeysZone() throws {
        let dates = RecordingDates(
            createDate: QuickTimeDate.parse("2026:10:09 06:00:05+00:00"),
            keysCreationDate: QuickTimeDate.parse("2026:10:09 14:00:05+08:00"))
        let args = try XCTUnwrap(MetadataCopier.writeDatesArguments(dates, file: URL(fileURLWithPath: "/o.mp4")))
        XCTAssertTrue(args.contains("-QuickTime:CreateDate=2026:10:09 14:00:05+08:00"))
        XCTAssertTrue(args.contains("-Track*Date=2026:10:09 14:00:05+08:00"))
        XCTAssertTrue(args.contains("-Media*Date=2026:10:09 14:00:05+08:00"))
        XCTAssertTrue(args.contains("-Keys:CreationDate=2026:10:09 14:00:05+08:00"))
        XCTAssertEqual(args.last, "/o.mp4")
        XCTAssertNil(MetadataCopier.writeDatesArguments(RecordingDates(), file: URL(fileURLWithPath: "/o.mp4")))
    }

    func testOnlyCreateDate() throws {
        let dates = RecordingDates(createDate: QuickTimeDate.parse("2026:10:09 06:00:05+00:00"))
        let args = try XCTUnwrap(MetadataCopier.writeDatesArguments(dates, file: URL(fileURLWithPath: "/o.mp4")))
        XCTAssertFalse(args.contains { $0.hasPrefix("-Keys:") }, "原来没有 Keys:CreationDate 就不添加")
    }

    func testParseDatesAndMatch() {
        let json = #"[{"SourceFile":"x","QuickTime:CreateDate":"2026:10:09 06:00:00+00:00","Keys:CreationDate":"2026:10:09 14:00:00+08:00"}]"#
        let dates = MetadataCopier.parseDates(Data(json.utf8))
        XCTAssertNotNil(dates.createDate)
        XCTAssertNotNil(dates.keysCreationDate)
        XCTAssertTrue(dates.matches(dates.shifted(by: 0.4)))
        XCTAssertFalse(dates.matches(dates.shifted(by: 5)))
        XCTAssertTrue(MetadataCopier.parseDates(Data("[]".utf8)).isEmpty)
    }
}

final class KeyframesTests: XCTestCase {
    func testArguments() {
        let url = URL(fileURLWithPath: "/a b.mp4")
        let args = Keyframes.arguments(for: url, around: 83.5)
        XCTAssertEqual(args, [
            "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
            "-read_intervals", "68.500000%+20.000000",
            "-show_entries", "frame=pts_time", "-of", "csv=p=0", url.path,
        ])
        XCTAssertEqual(Keyframes.arguments(for: url, around: 3)[7], "0.000000%+20.000000")
        XCTAssertEqual(Keyframes.arguments(for: url, around: 30, wholePrefix: true)[7], "%+31.000000")
        // 容器起始时间不是 0：读的位置要加上它。
        XCTAssertEqual(Keyframes.arguments(for: url, around: 20, startTime: 1.5)[7], "6.500000%+20.000000")
    }

    func testParseAndPick() {
        let out = "0.000000,\n4.000000\n8.000000\nN/A\n\n4.000000\n"
        let frames = Keyframes.parse(out)
        XCTAssertEqual(frames, [0, 4, 8])
        XCTAssertEqual(Keyframes.keyframe(atOrBefore: 5, in: frames), 4)
        XCTAssertEqual(Keyframes.keyframe(atOrBefore: 3.9995, in: frames), 4, "1 毫秒内的误差算同一个时间")
        XCTAssertEqual(Keyframes.keyframe(atOrBefore: 3.9, in: frames), 0)
        XCTAssertNil(Keyframes.keyframe(atOrBefore: 1, in: [2, 3]))
        XCTAssertEqual(Keyframes.parse("1.021000\n3.021000", startTime: 0.021), [1, 3])
    }
}

final class CutPlannerTests: XCTestCase {
    private func info(
        container: String = "mov,mp4,m4a,3gp,3g2,mj2", video: String = "h264", pix: String = "yuv420p",
        trc: String? = nil, audio: [String] = ["aac"], dolby: Bool = false
    ) -> MediaInfo {
        var streams = [MediaStream(
            index: 0, codecType: "video", codecName: video, width: 1920, height: 1080, pixelFormat: pix,
            frameRate: 30, colorTransfer: trc, colorPrimaries: trc == nil ? nil : "bt2020",
            colorSpace: trc == nil ? nil : "bt2020nc", colorRange: "tv", hasDolbyVision: dolby)]
        for (i, a) in audio.enumerated() {
            streams.append(MediaStream(index: i + 1, codecType: "audio", codecName: a))
        }
        return MediaInfo(formatName: container, duration: 100, streams: streams)
    }

    let input = URL(fileURLWithPath: "/in dir/源 'a'.mov")
    let output = URL(fileURLWithPath: "/out dir/o.mp4")

    func testValidate() throws {
        XCTAssertEqual(try CutPlanner.validate(CutRange(start: -1, end: 200), duration: 100), CutRange(start: 0, end: 100))
        XCTAssertThrowsError(try CutPlanner.validate(CutRange(start: 5, end: 5), duration: 100))
        XCTAssertThrowsError(try CutPlanner.validate(CutRange(start: 6, end: 5), duration: 100))
        XCTAssertThrowsError(try CutPlanner.validate(CutRange(start: 120, end: 130), duration: 100))
    }

    func testOutputExtension() {
        XCTAssertEqual(CutPlanner.outputExtension(for: info(), mode: .fast, sourceExtension: "MOV"), "mp4")
        XCTAssertEqual(CutPlanner.outputExtension(for: info(container: "matroska,webm"), mode: .fast, sourceExtension: "mkv"), "mp4")
        XCTAssertEqual(CutPlanner.outputExtension(for: info(container: "matroska,webm", audio: ["opus"]), mode: .fast, sourceExtension: "mkv"), "mkv")
        XCTAssertEqual(CutPlanner.outputExtension(for: info(container: "matroska,webm", video: "vp9"), mode: .fast, sourceExtension: "webm"), "webm")
        XCTAssertEqual(CutPlanner.outputExtension(for: info(audio: []), mode: .fast, sourceExtension: "mov"), "mp4")
        XCTAssertEqual(CutPlanner.outputExtension(for: info(container: "matroska,webm", audio: ["opus"]), mode: .precise, sourceExtension: "mkv"), "mp4")
    }

    func testFastArguments() {
        let args = CutPlanner.fastArguments(input: input, output: output, range: CutRange(start: 83.456, end: 95.456), info: info())
        XCTAssertEqual(args, [
            "-hide_banner", "-nostdin", "-n", "-progress", "pipe:1", "-nostats",
            "-ss", "83.456000", "-i", input.path, "-t", "12.000000",
            "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart", "-f", "mp4", output.path,
        ])
        let hevc = CutPlanner.fastArguments(input: input, output: output, range: CutRange(start: 1, end: 2), info: info(video: "hevc"))
        XCTAssertEqual(hevc[hevc.firstIndex(of: "-tag:v")! + 1], "hvc1")
        let mkv = CutPlanner.fastArguments(
            input: input, output: URL(fileURLWithPath: "/o.mkv"), range: CutRange(start: 1, end: 2), info: info(audio: ["opus"]))
        XCTAssertFalse(mkv.contains("-movflags"))
        XCTAssertEqual(mkv[mkv.firstIndex(of: "-f")! + 1], "matroska")
    }

    func testFastActualStart() {
        XCTAssertEqual(CutPlanner.fastActualStart(requested: 5, keyframeAtOrBefore: 4), 4)
        XCTAssertEqual(CutPlanner.fastActualStart(requested: 5, keyframeAtOrBefore: nil), 0)
        XCTAssertEqual(CutPlanner.fastActualStart(requested: 3.9995, keyframeAtOrBefore: 4), 3.9995)
    }

    func testCodecChoice() {
        func v(_ codec: String, _ pix: String = "yuv420p", _ trc: String? = nil) -> MediaStream {
            MediaStream(index: 0, codecType: "video", codecName: codec, pixelFormat: pix, colorTransfer: trc)
        }
        XCTAssertEqual(CutPlanner.videoCodec(for: v("h264")), .h264)
        XCTAssertEqual(CutPlanner.videoCodec(for: v("hevc")), .hevc)
        XCTAssertEqual(CutPlanner.videoCodec(for: v("mpeg4")), .h264)
        XCTAssertEqual(CutPlanner.videoCodec(for: v("vp9", "yuv420p10le")), .hevc)
        XCTAssertEqual(CutPlanner.videoCodec(for: v("h264", "yuv420p10le")), .hevc, "10-bit H.264 → HEVC main10")
        XCTAssertEqual(CutPlanner.videoCodec(for: v("vp9", "yuv420p", "smpte2084")), .hevc)
    }

    func testPreciseVideoToolboxH264() throws {
        let args = try CutPlanner.preciseArguments(
            input: input, output: output, range: CutRange(start: 5.5, end: 7.5), info: info(), encoder: .videoToolbox)
        XCTAssertEqual(Array(args[0...8]), [
            "-hide_banner", "-nostdin", "-n", "-progress", "pipe:1", "-nostats", "-ss", "5.500000", "-i",
        ])
        XCTAssertEqual(args[args.firstIndex(of: "-t")! + 1], "2.000000")
        XCTAssertEqual(args[args.firstIndex(of: "-c:v")! + 1], "h264_videotoolbox")
        XCTAssertEqual(args[args.firstIndex(of: "-q:v")! + 1], "65")
        XCTAssertEqual(args[args.firstIndex(of: "-c:a")! + 1], "aac")
        XCTAssertEqual(args[args.firstIndex(of: "-b:a")! + 1], "192k")
        XCTAssertTrue(args.contains("0:a?"))
        XCTAssertEqual(args.suffix(3), ["-f", "mp4", output.path])
    }

    func testPreciseHDRKeepsColorAnd10Bit() throws {
        let hdr = info(video: "hevc", pix: "yuv420p10le", trc: "smpte2084")
        let args = try CutPlanner.preciseArguments(
            input: input, output: output, range: CutRange(start: 1, end: 2), info: hdr, encoder: .videoToolbox)
        XCTAssertEqual(args[args.firstIndex(of: "-c:v")! + 1], "hevc_videotoolbox")
        XCTAssertEqual(args[args.firstIndex(of: "-tag:v")! + 1], "hvc1")
        XCTAssertEqual(args[args.firstIndex(of: "-profile:v")! + 1], "main10")
        XCTAssertEqual(args[args.firstIndex(of: "-pix_fmt")! + 1], "p010le")
        XCTAssertEqual(args[args.firstIndex(of: "-color_trc")! + 1], "smpte2084")
        XCTAssertEqual(args[args.firstIndex(of: "-color_primaries")! + 1], "bt2020")
        XCTAssertEqual(args[args.firstIndex(of: "-colorspace")! + 1], "bt2020nc")
        XCTAssertEqual(args[args.firstIndex(of: "-color_range")! + 1], "tv")

        let sw = try CutPlanner.preciseArguments(
            input: input, output: output, range: CutRange(start: 1, end: 2), info: hdr, encoder: .software(lossless: true))
        XCTAssertEqual(sw[sw.firstIndex(of: "-c:v")! + 1], "libx265")
        XCTAssertEqual(sw[sw.firstIndex(of: "-pix_fmt")! + 1], "yuv420p10le")
        XCTAssertTrue(sw[sw.firstIndex(of: "-x265-params")! + 1].contains("lossless=1"))
    }

    func testNoAudioMeansNoAudioCodec() throws {
        let args = try CutPlanner.preciseArguments(
            input: input, output: output, range: CutRange(start: 1, end: 2), info: info(audio: []), encoder: .videoToolbox)
        XCTAssertFalse(args.contains("-c:a"))
    }

    func testDolbyVisionWarning() {
        XCTAssertEqual(CutPlanner.warnings(for: info(video: "hevc", dolby: true), mode: .precise).count, 1)
        XCTAssertTrue(CutPlanner.warnings(for: info(video: "hevc", dolby: true), mode: .fast).isEmpty)
        XCTAssertTrue(CutPlanner.warnings(for: info(), mode: .precise).isEmpty)
    }

    func testDolbyVisionDetectionFromProbe() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","codec_tag_string":"hvc1","#
            + #""side_data_list":[{"side_data_type":"DOVI configuration record","dv_profile":8}]}],"format":{"format_name":"mov","start_time":"0.5"}}"#
        let parsed = try MediaInfo.parse(Data(json.utf8))
        XCTAssertEqual(parsed.videoStream?.hasDolbyVision, true)
        XCTAssertEqual(parsed.startTime, 0.5)
        let tagged = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"hevc","codec_tag_string":"dvh1"}],"format":{}}"#
        XCTAssertEqual(try MediaInfo.parse(Data(tagged.utf8)).videoStream?.hasDolbyVision, true)
    }

    func testLeadInMessage() {
        var plan = CutPlan(
            source: input, output: output, range: CutRange(start: 83.456, end: 95), options: CutOptions(mode: .fast),
            actualStart: 81.623, arguments: [], warnings: [], encoderDescription: nil, copiesMetadata: true)
        XCTAssertEqual(plan.leadIn, 1.833, accuracy: 1e-9)
        XCTAssertEqual(plan.leadInMessage, "实际起点会提前 1.833 秒（从 00:01:21.623 开始，那里是最近的关键帧）。")
        XCTAssertEqual(plan.outputDuration, 95 - 81.623, accuracy: 1e-9)
        plan.options.mode = .precise
        XCTAssertNil(plan.leadInMessage)
    }
}
