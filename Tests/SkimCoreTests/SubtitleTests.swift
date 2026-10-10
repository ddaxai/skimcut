import Foundation
import XCTest
@testable import SkimCore

final class SubtitleFormatTests: XCTestCase {
    func testDetect() {
        func f(_ name: String, idx: Bool = false) -> SubtitleFormat? {
            SubtitleFormat.detect(URL(fileURLWithPath: "/x/\(name)")) { _ in idx }
        }
        XCTAssertEqual(f("a.SRT"), .srt)
        XCTAssertEqual(f("a.ass"), .ass)
        XCTAssertEqual(f("a.ssa"), .ssa)
        XCTAssertEqual(f("a.vtt"), .vtt)
        XCTAssertEqual(f("a.sup"), .sup)
        XCTAssertEqual(f("a.idx"), .vobsub)
        XCTAssertEqual(f("a.sub", idx: true), .vobsub)
        XCTAssertNil(f("a.sub"), "没有 .idx 的 .sub（MicroDVD 文字字幕）不支持")
        XCTAssertNil(f("a.mp4"))
        XCTAssertTrue(SubtitleFormat.isSubtitleFile(URL(fileURLWithPath: "/a.Srt")))
        XCTAssertFalse(SubtitleFormat.isSubtitleFile(URL(fileURLWithPath: "/a.mkv")))
    }

    func testCodecMapping() {
        XCTAssertEqual(SubtitleFormat.fromCodec("subrip"), .srt)
        XCTAssertEqual(SubtitleFormat.fromCodec("mov_text"), .movText)
        XCTAssertEqual(SubtitleFormat.fromCodec("hdmv_pgs_subtitle"), .sup)
        XCTAssertEqual(SubtitleFormat.fromCodec("dvd_subtitle"), .vobsub)
        XCTAssertNil(SubtitleFormat.fromCodec("eia_608"))
        XCTAssertTrue(SubtitleFormat.ass.hasStyles)
        XCTAssertFalse(SubtitleFormat.srt.hasStyles)
        XCTAssertFalse(SubtitleFormat.sup.isText)
    }

    func testLanguageNormalize() {
        XCTAssertEqual(SubtitleLanguages.normalize(" CHI "), "chi")
        XCTAssertEqual(SubtitleLanguages.normalize("en"), "en")
        XCTAssertEqual(SubtitleLanguages.normalize(""), "und")
        XCTAssertEqual(SubtitleLanguages.normalize("中文"), "und")
        XCTAssertEqual(SubtitleLanguages.normalize("chinese"), "und")
    }

    func testEncodingNames() {
        XCTAssertTrue(SubtitleEncoding.isUTF8("UTF-8"))
        XCTAssertTrue(SubtitleEncoding.isUTF8("ascii"))
        XCTAssertFalse(SubtitleEncoding.isUTF8("GB18030"))
        XCTAssertTrue(SubtitleEncoding.isUnknown("unknown"))
        XCTAssertTrue(SubtitleEncoding.isUnknown(""))
        XCTAssertEqual(SubtitleEncoding.displayName("GB18030"), "GB18030（GBK）")
        XCTAssertEqual(SubtitleEncoding.convertArguments(URL(fileURLWithPath: "/a b.srt"), from: "BIG5"),
                       ["-f", "BIG5", "-t", "UTF-8", "/a b.srt"])
    }
}

final class SubtitleShifterTests: XCTestCase {
    let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    第一条

    2
    00:00:04,000 --> 00:00:06,000
    第二条
    两行

    3
    00:00:07,250 --> 00:00:09,750 X1:10 X2:20
    第三条

    """

    func testSRTShiftDropsAndClamps() {
        let out = SubtitleShifter.shift(srt, format: .srt, by: 2)
        XCTAssertEqual(out, """
        1
        00:00:00,000 --> 00:00:01,500
        第一条

        2
        00:00:02,000 --> 00:00:04,000
        第二条
        两行

        3
        00:00:05,250 --> 00:00:07,750 X1:10 X2:20
        第三条

        """)
    }

    func testSRTShiftWithDurationAndRenumber() {
        // 从 3.6 秒开始取 4 秒（到 7.6 秒）：第一条完全在外面，第三条被截尾，序号重新从 1 开始。
        let out = SubtitleShifter.shift(srt, format: .srt, by: 3.6, duration: 4)
        XCTAssertEqual(out, """
        1
        00:00:00,400 --> 00:00:02,400
        第二条
        两行

        2
        00:00:03,650 --> 00:00:04,000 X1:10 X2:20
        第三条

        """)
    }

    func testSRTWithCRLFAndZeroOffset() {
        let crlf = srt.replacingOccurrences(of: "\n", with: "\r\n")
        let out = SubtitleShifter.shift(crlf, format: .srt, by: 0)
        XCTAssertTrue(out.hasPrefix("1\n00:00:01,000 --> 00:00:03,500\n第一条"))
        XCTAssertTrue(out.contains("00:00:07,250 --> 00:00:09,750"))
    }

    func testVTTKeepsHeaderAndUsesDots() {
        let vtt = """
        WEBVTT

        NOTE 注释

        intro
        00:01.000 --> 00:03.500 align:start
        第一条

        01:00:04.000 --> 01:00:06.000
        一小时后

        """
        let out = SubtitleShifter.shift(vtt, format: .vtt, by: 2)
        XCTAssertEqual(out, """
        WEBVTT

        NOTE 注释

        intro
        00:00:00.000 --> 00:00:01.500 align:start
        第一条

        01:00:02.000 --> 01:00:04.000
        一小时后

        """)
    }

    func testASSShiftKeepsStylesAndCommasInText() {
        let ass = """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Yellow,PingFang SC,40

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,第一条, 带逗号
        Comment: 0,0:00:01.50,0:00:02.00,Default,,0,0,0,,注释
        Dialogue: 0,0:00:04.00,0:00:06.00,Yellow,,0,0,0,,{\\i1}带样式{\\i0}
        Dialogue: 0,1:00:00.00,1:00:01.00,Default,,0,0,0,,很后面
        """
        let out = SubtitleShifter.shift(ass, format: .ass, by: 2, duration: 10)
        XCTAssertEqual(out, """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Yellow,PingFang SC,40

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:01.50,Default,,0,0,0,,第一条, 带逗号
        Dialogue: 0,0:00:02.00,0:00:04.00,Yellow,,0,0,0,,{\\i1}带样式{\\i0}
        """, "注释（1.5–2.0 秒）在起点之前，去掉；一小时后的在区间外，去掉")
    }

    func testASSCustomFieldOrder() {
        let ass = """
        [Events]
        Format: Start, End, Style, Text
        Dialogue: 0:00:05.00,0:00:06.00,Default,文字
        """
        XCTAssertEqual(SubtitleShifter.shift(ass, format: .ass, by: 1.5), """
        [Events]
        Format: Start, End, Style, Text
        Dialogue: 0:00:03.50,0:00:04.50,Default,文字
        """)
    }

    func testTimeHelpers() {
        XCTAssertEqual(SubtitleShifter.parseCueTime("01:02:03,500"), 3723.5)
        XCTAssertEqual(SubtitleShifter.parseCueTime("02:03.5"), 123.5)
        XCTAssertNil(SubtitleShifter.parseCueTime("abc"))
        XCTAssertEqual(SubtitleShifter.formatCueTime(3723.5, .srt), "01:02:03,500")
        XCTAssertEqual(SubtitleShifter.formatASSTime(3723.456), "1:02:03.46")
        XCTAssertEqual(SubtitleShifter.parseASSTime("1:02:03.46"), 3723.46)
    }
}

final class SubtitlePlannerTests: XCTestCase {
    let srtTrack = SubtitleTrack(source: .file(URL(fileURLWithPath: "/s/a.srt")), format: .srt, isDefault: true)
    let assTrack = SubtitleTrack(source: .file(URL(fileURLWithPath: "/s/b.ass")), format: .ass, language: "eng", title: "样式 字幕")
    let supTrack = SubtitleTrack(source: .file(URL(fileURLWithPath: "/s/c.sup")), format: .sup)

    func testContainersAndWarnings() {
        XCTAssertEqual(SubtitlePlanner.allowedContainers([srtTrack, assTrack]), [.mp4, .mkv])
        XCTAssertEqual(SubtitlePlanner.allowedContainers([srtTrack, supTrack]), [.mkv])
        XCTAssertEqual(SubtitlePlanner.warnings([assTrack], container: .mp4).count, 1)
        XCTAssertTrue(SubtitlePlanner.warnings([assTrack], container: .mkv).isEmpty)
        XCTAssertTrue(SubtitlePlanner.warnings([srtTrack], container: .mp4).isEmpty)
    }

    func testValidate() {
        XCTAssertThrowsError(try SubtitlePlanner.validate([], container: .mkv, cutting: false))
        XCTAssertThrowsError(try SubtitlePlanner.validate([supTrack], container: .mp4, cutting: false)) {
            XCTAssertEqual($0 as? SubtitleError, .bitmapNeedsMKV)
        }
        XCTAssertNoThrow(try SubtitlePlanner.validate([supTrack], container: .mkv, cutting: false))
        XCTAssertThrowsError(try SubtitlePlanner.validate([supTrack], container: .mkv, cutting: true)) {
            XCTAssertEqual($0 as? SubtitleError, .bitmapCannotBeCut)
        }
    }

    func testOutputCodec() {
        XCTAssertEqual(SubtitlePlanner.outputCodec(for: .ass, container: .mp4), "mov_text")
        XCTAssertEqual(SubtitlePlanner.outputCodec(for: .ass, container: .mkv), "copy")
        XCTAssertEqual(SubtitlePlanner.outputCodec(for: .movText, container: .mkv), "srt")
    }

    func testFileName() {
        let src = URL(fileURLWithPath: "/m/我的 视频.mov")
        XCTAssertEqual(SubtitlePlanner.outputFileName(source: src, range: nil, container: .mp4), "我的 视频_subs.mp4")
        XCTAssertEqual(SubtitlePlanner.outputFileName(source: src, range: CutRange(start: 83.456, end: 95.456), container: .mkv),
                       "我的 视频_cut_01m23.456s-01m35.456s_subs.mkv")
    }

    func testMuxArgumentsMP4() {
        let base = URL(fileURLWithPath: "/m/v 1.mp4")
        let out = URL(fileURLWithPath: "/m/out.mp4")
        let embedded = SubtitleTrack(source: .embedded(streamIndex: 2), format: .movText, language: "jpn")
        let args = SubtitlePlanner.muxArguments(
            base: base, embedded: [(embedded, "0:2")],
            external: [.init(track: srtTrack, file: URL(fileURLWithPath: "/t/track0.srt")),
                       .init(track: assTrack, file: URL(fileURLWithPath: "/t/track1.ass"))],
            container: .mp4, videoCodec: "hevc", output: out)
        XCTAssertEqual(args, [
            "-hide_banner", "-nostdin", "-n", "-progress", "pipe:1", "-nostats",
            "-i", base.path,
            "-sub_charenc", "UTF-8", "-i", "/t/track0.srt",
            "-sub_charenc", "UTF-8", "-i", "/t/track1.ass",
            "-map", "0:v:0", "-map", "0:a?", "-map", "0:2", "-map", "1:0", "-map", "2:0",
            "-c:v", "copy", "-c:a", "copy",
            "-c:s:0", "mov_text", "-metadata:s:s:0", "language=jpn", "-disposition:s:0", "0",
            "-c:s:1", "mov_text", "-metadata:s:s:1", "language=chi", "-disposition:s:1", "default",
            "-c:s:2", "mov_text", "-metadata:s:s:2", "language=eng",
            "-metadata:s:s:2", "title=样式 字幕", "-metadata:s:s:2", "handler_name=样式 字幕", "-disposition:s:2", "0",
            "-tag:v", "hvc1", "-movflags", "+faststart", "-f", "mp4", out.path,
        ])
    }

    func testMuxArgumentsMKVAndBitmap() {
        let args = SubtitlePlanner.muxArguments(
            base: URL(fileURLWithPath: "/m/cut.mkv"), embedded: [],
            external: [.init(track: supTrack, file: URL(fileURLWithPath: "/s/c.sup"))],
            container: .mkv, videoCodec: "h264", output: URL(fileURLWithPath: "/o.mkv"))
        XCTAssertFalse(args.contains("-sub_charenc"), "图形字幕不设文字编码")
        XCTAssertTrue(args.contains("matroska"))
        XCTAssertFalse(args.contains("-movflags"))
        XCTAssertEqual(args[args.firstIndex(of: "-c:s:0")! + 1], "copy")
    }

    func testCutArguments() {
        let args = SubtitlePlanner.cutArguments(
            source: URL(fileURLWithPath: "/m/a.mkv"), range: CutRange(start: 5, end: 7), embeddedStreams: [2, 4],
            output: URL(fileURLWithPath: "/t/cut.mkv"))
        XCTAssertEqual(Array(args.suffix(15)), [
            "-map", "0:v:0", "-map", "0:a?", "-map", "0:2", "-map", "0:4",
            "-c", "copy", "-avoid_negative_ts", "make_zero", "-f", "matroska", "/t/cut.mkv",
        ])
        XCTAssertEqual(args.last, "/t/cut.mkv")
        XCTAssertEqual(args[args.firstIndex(of: "-ss")! + 1], "5.000000")
        XCTAssertEqual(args[args.firstIndex(of: "-t")! + 1], "2.000000")
    }

    func testEmbeddedTrackFromStream() {
        let stream = MediaStream(index: 3, codecType: "subtitle", codecName: "subrip", language: "ENG", title: "English", isDefault: true)
        let track = SubtitleTrack.embedded(stream)
        XCTAssertEqual(track?.source, .embedded(streamIndex: 3))
        XCTAssertEqual(track?.language, "eng")
        XCTAssertEqual(track?.title, "English")
        XCTAssertEqual(track?.isDefault, true)
        XCTAssertNil(SubtitleTrack.embedded(MediaStream(index: 0, codecType: "video", codecName: "h264")))
    }
}
