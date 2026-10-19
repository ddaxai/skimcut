import Foundation
import XCTest
@testable import SkimCore

/// 一次导出：命名、局部压低换算（不运行外部工具）。
final class PipelineTests: XCTestCase {
    let source = URL(fileURLWithPath: "/v/旅行 1.mov")

    func testOutputFileName() {
        var job = PipelineJob(source: source, range: CutRange(start: 83.456, end: 95.456))
        XCTAssertEqual(PipelinePlanner.outputFileName(job, extension: "mov"), "旅行 1_cut_01m23.456s-01m35.456s.mov")
        job.volume = NormalizeOptions()
        job.subtitles = .init(tracks: [], container: .mkv)
        XCTAssertEqual(PipelinePlanner.outputFileName(job, extension: "mkv"), "旅行 1_cut_01m23.456s-01m35.456s_norm_nosubs.mkv")
        job.range = nil
        job.subtitles = .init(tracks: [SubtitleTrack(source: .file(URL(fileURLWithPath: "/a.srt")), format: .srt)], container: .mp4)
        XCTAssertEqual(PipelinePlanner.outputFileName(job, extension: "mp4"), "旅行 1_norm_subs.mp4")
    }

    func testHasSteps() {
        XCTAssertFalse(PipelineJob(source: source).hasSteps)
        XCTAssertTrue(PipelineJob(source: source, volume: NormalizeOptions()).hasSteps)
    }

    func testShiftDucks() {
        let ducks = [
            VolumeDuck(start: 1, end: 2, gain: -6),      // 在片段之前
            VolumeDuck(start: 9.5, end: 10.5, gain: -9), // 跨过起点
            VolumeDuck(start: 12, end: 13, gain: -12),   // 在片段里
            VolumeDuck(start: 19, end: 25, gain: -3),    // 跨过终点
        ]
        XCTAssertEqual(PipelinePlanner.shiftDucks(ducks, by: 10, length: 10), [
            VolumeDuck(start: 0, end: 0.5, gain: -9),
            VolumeDuck(start: 2, end: 3, gain: -12),
            VolumeDuck(start: 9, end: 10, gain: -3),
        ])
    }

    func testReplacementURL() {
        XCTAssertEqual(PipelinePlanner.replacementURL(original: source, newFile: URL(fileURLWithPath: "/out/x.mov")).path, "/v/旅行 1.mov")
        XCTAssertEqual(PipelinePlanner.replacementURL(original: URL(fileURLWithPath: "/v/a.avi"), newFile: URL(fileURLWithPath: "/v/a_norm.mkv")).path, "/v/a.mkv")
    }

    func testMuxArgumentsWithStreamFromAnotherFile() {
        let track = SubtitleTrack(source: .embedded(streamIndex: 2), format: .ass)
        let args = SubtitlePlanner.muxArguments(
            base: URL(fileURLWithPath: "/w/base.mkv"),
            tracks: [.init(track: track, input: .stream(URL(fileURLWithPath: "/v/orig.mkv"), index: 2))],
            container: .mkv, videoCodec: "h264", output: URL(fileURLWithPath: "/w/out.mkv"))
        XCTAssertEqual(Array(args[args.firstIndex(of: "-i")!...].prefix(4)), ["-i", "/w/base.mkv", "-i", "/v/orig.mkv"])
        XCTAssertTrue(args.contains("1:2"))
        XCTAssertFalse(args.contains("-sub_charenc"), "原文件里的流不按 UTF-8 重新读")
    }
}
