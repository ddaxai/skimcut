import Foundation
import XCTest
@testable import SkimCore

/// 真正运行外部工具的一次导出测试。
final class PipelineIntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func requireAll() throws {
        for tool in [Tool.ffmpegNormalize, .exiftool, .uchardet] { _ = try TestSupport.requireTool(tool) }
    }

    private func copy(_ name: String, as newName: String? = nil) throws -> URL {
        let media = try TestSupport.testMedia()
        let target = dir.appendingPathComponent(newName ?? name)
        try FileManager.default.copyItem(at: media.appendingPathComponent(name), to: target)
        return target
    }

    private func exporter(trashDir: URL? = nil) -> PipelineExporter {
        guard let trashDir else { return PipelineExporter(runner: runner, encoder: .software(lossless: false)) }
        return PipelineExporter(runner: runner, encoder: .software(lossless: false)) { url in
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        }
    }

    private func visibleFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 剪切（精确）+ 统一音量 + 外部字幕 + 元数据：只生成一个文件，每一步的结果都在里面。
    func testCutNormalizeSubtitlesAndMetadata() async throws {
        try requireAll()
        let source = try copy("h264_gop4.mp4", as: "clip.mp4")
        _ = try await runner.run(try ToolLocator.shared.command(.exiftool, [
            "-q", "-overwrite_original", "-api", "QuickTimeUTC",
            "-QuickTime:CreateDate=2024:05:06 07:08:09+08:00", "-Keys:CreationDate=2024:05:06 07:08:09+08:00", source.path,
        ]))
        let srt = try copy("subs_gbk.srt")
        let job = PipelineJob(
            source: source, range: CutRange(start: 5, end: 9), cutMode: .precise, volume: NormalizeOptions(),
            subtitles: .init(tracks: [SubtitleTrack(source: .file(srt), format: .srt, isDefault: true)], container: .mp4))
        let result = try await exporter().export(job)
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(output.lastPathComponent, "clip_cut_00m05.000s-00m09.000s_norm_subs.mp4")
        XCTAssertEqual(try XCTUnwrap(result.actualStart), 5, accuracy: 0.001, "精确模式")
        XCTAssertEqual(try visibleFiles(), ["clip.mp4", "clip_cut_00m05.000s-00m09.000s_norm_subs.mp4", "subs_gbk.srt"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".skimcut-pipeline") },
                       "中间文件夹已经删除")

        let info = try await MediaInfo.probe(output, runner: runner)
        XCTAssertEqual(try XCTUnwrap(info.bestDuration), 4, accuracy: 0.1)
        XCTAssertEqual(info.subtitleStreams.count, 1)
        let loudness = try await LoudnessAnalyzer.analyze(output, duration: nil, includeMomentary: false, runner: runner)
        XCTAssertEqual(loudness.stats.integrated, -16, accuracy: 1)

        // 源字幕 4.0–6.0 → 片段里 0–1 秒（从 5 秒开始剪）。
        let text = try await runner.output(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", output.path, "-map", "0:s:0", "-f", "srt", "-",
        ]))
        let first = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("-->") })
        let timing = try XCTUnwrap(SubtitleShifter.parseTimingLine(String(first)))
        let (a, b) = (timing.0, timing.1)
        XCTAssertEqual(a, 0, accuracy: 0.05)
        XCTAssertEqual(b, 1, accuracy: 0.05)

        // 录制时间 = 原录制时间 + 5 秒。
        let dates = try await MetadataCopier(runner: runner).readDates(output)
        XCTAssertEqual(dates.keysCreationDate?.exifToolString, "2024:05:06 07:08:14+08:00")
    }

    /// 不剪切、保留原有字幕（从原文件取）、统一音量，输出 MKV。
    func testKeepEmbeddedSubtitlesWithoutCut() async throws {
        try requireAll()
        let media = try TestSupport.testMedia()
        let source = dir.appendingPathComponent("with subs.mkv")
        _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", media.appendingPathComponent("sample.mkv").path,
            "-i", media.appendingPathComponent("subs.ass").path,
            "-map", "0", "-map", "1", "-c", "copy", "-metadata:s:s:0", "language=jpn", source.path,
        ]))
        let info = try await MediaInfo.probe(source, runner: runner)
        let embedded = info.subtitleStreams.compactMap(SubtitleTrack.embedded)
        let result = try await exporter().export(PipelineJob(
            source: source, volume: NormalizeOptions(), subtitles: .init(tracks: embedded, container: .mkv)))
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(output.lastPathComponent, "with subs_norm_subs.mkv")
        let out = try await MediaInfo.probe(output, runner: runner)
        XCTAssertEqual(out.subtitleStreams.map(\.codecName), ["ass"], "ASS 样式保留")
        XCTAssertEqual(out.subtitleStreams.first?.language, "jpn")
        XCTAssertEqual(out.audioStreams.first?.codecName, "aac")
    }

    /// 剪切时原有的文字字幕从原文件取出来，按实际起点平移。
    func testCutWithEmbeddedTextSubtitle() async throws {
        try requireAll()
        let media = try TestSupport.testMedia()
        let source = dir.appendingPathComponent("src.mkv")
        _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", media.appendingPathComponent("h264_gop4.mp4").path,
            "-sub_charenc", "GB18030", "-i", media.appendingPathComponent("subs_gbk.srt").path,
            "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", "srt", source.path,
        ]))
        let info = try await MediaInfo.probe(source, runner: runner)
        let job = PipelineJob(
            source: source, range: CutRange(start: 5, end: 9), cutMode: .fast,
            subtitles: .init(tracks: info.subtitleStreams.compactMap(SubtitleTrack.embedded), container: .mkv))
        let result = try await exporter().export(job)
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(try XCTUnwrap(result.actualStart), 4, accuracy: 0.05, "快速模式：起点之前的关键帧（MKV 里约 4.02 秒）")
        let text = try await runner.output(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", output.path, "-map", "0:s:0", "-f", "srt", "-",
        ]))
        XCTAssertFalse(text.contains("第一条字幕"), "起点之前的去掉")
        let cues = text.split(separator: "\n").filter { $0.contains("-->") }.compactMap { SubtitleShifter.parseTimingLine(String($0)) }
        XCTAssertEqual(cues.count, 2, text)
        // 源 4.0 秒 → 片段的第一帧 v0（不到 0.1 秒）。
        XCTAssertLessThan(try XCTUnwrap(cues.first).0, 0.1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(cues.last).1, 5.1, "截到终点")
    }

    /// 只统一音量，而且已经接近目标：什么都不生成。
    func testNothingToChange() async throws {
        try requireAll()
        let normalized = try await VolumeExporter(runner: runner, cache: nil)
            .export(VolumeJob(source: try copy("loud_loud.mp4"), outputDirectory: dir))
        let input = try XCTUnwrap(normalized.output)
        let before = try visibleFiles()
        let result = try await exporter().export(PipelineJob(source: input, volume: NormalizeOptions()))
        XCTAssertNil(result.output)
        XCTAssertEqual(try visibleFiles(), before)
        do {
            _ = try await exporter().export(PipelineJob(source: input))
            XCTFail("没有步骤")
        } catch {
            XCTAssertEqual(error as? PipelineError, .nothingToDo)
        }
    }

    /// 替换原文件：原文件进“废纸篓”，新文件改用原文件的名字。
    func testReplaceOriginal() async throws {
        try requireAll()
        let source = try copy("loud_quiet.mp4", as: "quiet.mp4")
        let trash = dir.appendingPathComponent("trash")
        let result = try await exporter(trashDir: trash).export(
            PipelineJob(source: source, volume: NormalizeOptions(), replaceOriginal: true))
        XCTAssertTrue(result.replacedOriginal)
        XCTAssertEqual(result.output?.path, source.path, "新文件用原来的名字")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("quiet.mp4").path), "原文件在废纸篓里")
        let loudness = try await LoudnessAnalyzer.analyze(source, duration: nil, includeMomentary: false, runner: runner)
        XCTAssertEqual(loudness.stats.integrated, -16, accuracy: 1, "原名字现在是处理后的文件")
        XCTAssertEqual(try visibleFiles(), ["quiet.mp4", "trash"])
    }

    /// 局部压低的时间是原文件里的时间：剪切后要换算。
    func testDucksAreShiftedAfterCut() async throws {
        try requireAll()
        let source = try copy("loud_loud.mp4", as: "duck.mp4")
        // 原文件 6–8 秒压低；从 4 秒剪到 10 秒，片段里是 2–4 秒。
        let options = NormalizeOptions(ducks: [VolumeDuck(start: 6, end: 8, gain: -12)])
        let result = try await exporter().export(PipelineJob(
            source: source, range: CutRange(start: 4, end: 10), cutMode: .precise, volume: options))
        let analysis = try await LoudnessAnalyzer.analyze(try XCTUnwrap(result.output), duration: nil, runner: runner)
        func at(_ t: Double) -> Double {
            let i = analysis.momentary.times.enumerated().min { abs(Double($0.element) - t) < abs(Double($1.element) - t) }!.offset
            return Double(analysis.momentary.values[i])
        }
        XCTAssertEqual(at(5.5) - at(3.5), 12, accuracy: 2)
    }
}
