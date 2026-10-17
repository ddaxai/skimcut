import Foundation
import XCTest
@testable import SkimCore

/// 真正运行 ffmpeg / ffmpeg-normalize / exiftool 的音量测试。
final class VolumeIntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())
    private var dir: URL!
    private var cache: LoudnessCache!

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempDir()
        cache = LoudnessCache(directory: dir.appendingPathComponent("cache"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func exporter() -> VolumeExporter {
        VolumeExporter(runner: runner, cache: cache)
    }

    private func requireNormalizeTools() throws {
        _ = try TestSupport.requireTool(.ffmpegNormalize)
        _ = try TestSupport.requireTool(.exiftool)
    }

    /// 视频流的 MD5（只复制，不解码）：相同就说明视频没有重新编码。
    private func videoHash(_ url: URL) async throws -> String {
        try await runner.output(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "md5", "-",
        ])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func measure(_ url: URL) async throws -> LoudnessAnalysis {
        try await LoudnessAnalyzer.analyze(url, duration: nil, runner: runner)
    }

    /// 某个时间附近的短时响度。
    private func momentary(_ analysis: LoudnessAnalysis, at time: Double) -> Double {
        let i = analysis.momentary.times.enumerated().min { abs(Double($0.element) - time) < abs(Double($1.element) - time) }!.offset
        return Double(analysis.momentary.values[i])
    }

    private func outputFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "cache" }.sorted()
    }

    // MARK: - 检测

    func testDetectsLoudnessAndBursts() async throws {
        let media = try TestSupport.testMedia()
        let analysis = try await exporter().analyze(media.appendingPathComponent("bursts.mp4"), duration: 30)
        XCTAssertEqual(analysis.stats.integrated, -37, accuracy: 2)
        XCTAssertGreaterThan(analysis.momentary.values.count, 280, "每 0.1 秒一个值")
        let bursts = analysis.bursts(margin: 10)
        XCTAssertEqual(bursts.count, 2, "\(bursts)（开头约 -120 的值不算）")
        for (burst, (a, b)) in zip(bursts, [(10.0, 10.3), (20.0, 20.2)]) {
            XCTAssertLessThanOrEqual(burst.start, a)
            XCTAssertGreaterThanOrEqual(burst.end, b)
            XCTAssertLessThan(burst.duration, 1.5)
        }
        // 第二次直接读缓存。
        XCTAssertEqual(cache.analysis(for: media.appendingPathComponent("bursts.mp4")), analysis)
    }

    func testMomentaryPathWithSpecialCharacters() async throws {
        let media = try TestSupport.testMedia()
        let momentary = dir.appendingPathComponent("r128 a,b:c'd[e].txt")
        let args = LoudnessAnalyzer.arguments(input: media.appendingPathComponent("loud_medium.mp4"), momentaryFile: momentary)
        let result = try await runner.run(try ToolLocator.shared.command(.ffmpeg, args))
        XCTAssertEqual(try LoudnessAnalyzer.parseStats(result.stderrText).integrated, -35, accuracy: 2)
        let text = try String(contentsOf: momentary, encoding: .utf8)
        XCTAssertGreaterThan(LoudnessAnalyzer.parseMomentary(text).values.count, 90)
    }

    func testNoAudio() async throws {
        let media = try TestSupport.testMedia()
        let silentVideo = dir.appendingPathComponent("video only.mp4")
        _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", media.appendingPathComponent("loud_medium.mp4").path,
            "-an", "-c", "copy", silentVideo.path,
        ]))
        do {
            _ = try await LoudnessAnalyzer.analyze(silentVideo, duration: nil, runner: runner)
            XCTFail("应该报没有音轨")
        } catch {
            XCTAssertEqual(error as? LoudnessError, .noAudio)
        }
        try requireNormalizeTools()
        do {
            _ = try await exporter().export(VolumeJob(source: silentVideo, outputDirectory: dir))
            XCTFail("应该报没有音轨")
        } catch {
            XCTAssertEqual(error as? LoudnessError, .noAudio)
        }
    }

    // MARK: - 统一音量（M4 验收）

    /// 3 个音量相差约 30 dB 的视频，处理后都在目标值 ±1 LU 以内；视频流和原文件完全相同。
    func testAcceptanceThreeVideosReachTargetWithoutReencodingVideo() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        for name in ["loud_quiet", "loud_medium", "loud_loud"] {
            let source = media.appendingPathComponent("\(name).mp4")
            let result = try await exporter().export(VolumeJob(source: source, outputDirectory: dir))
            let output = try XCTUnwrap(result.output, name)
            XCTAssertEqual(output.lastPathComponent, "\(name)_norm.mp4")
            XCTAssertEqual(try XCTUnwrap(result.after).integrated, -16, accuracy: 1, name)

            // 独立重新测量，不用 exporter 的结果。
            let measured = try await measure(output)
            XCTAssertEqual(measured.stats.integrated, -16, accuracy: 1, "\(name)：\(measured.stats.summary)")
            XCTAssertLessThanOrEqual(measured.stats.truePeak, -1.5 + 0.5, name)

            let sourceHash = try await videoHash(source)
            let outputHash = try await videoHash(output)
            XCTAssertEqual(outputHash, sourceHash, "\(name)：视频流应该直接复制")

            let info = try await MediaInfo.probe(output, runner: runner)
            XCTAssertEqual(info.audioStreams.first?.codecName, "aac")
            let rate = try await runner.output(try ToolLocator.shared.command(.ffprobe, [
                "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate", "-of", "csv=p=0", output.path,
            ])).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(rate, "48000", "必须加 -ar 48000")
        }
        // 没有留下隐藏的临时文件。
        XCTAssertEqual(try outputFiles(), ["loud_loud_norm.mp4", "loud_medium_norm.mp4", "loud_quiet_norm.mp4"])
    }

    func testAlreadyNormalizedIsSkippedWithoutNewFile() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        let first = try await exporter().export(VolumeJob(source: media.appendingPathComponent("loud_loud.mp4"), outputDirectory: dir))
        let normalized = try XCTUnwrap(first.output)
        let again = try await exporter().export(VolumeJob(source: normalized, outputDirectory: dir))
        XCTAssertTrue(again.skipped)
        XCTAssertNil(again.after)
        XCTAssertEqual(try outputFiles(), ["loud_loud_norm.mp4"], "跳过时不生成新文件")

        // 同名文件已经存在：加序号，不覆盖。
        let second = try await exporter().export(VolumeJob(
            source: media.appendingPathComponent("loud_loud.mp4"), options: NormalizeOptions(highpass: true), outputDirectory: dir))
        XCTAssertEqual(second.output?.lastPathComponent, "loud_loud_norm_2.mp4")
    }

    /// 局部压低：表达式里的逗号要转义；那一段的短时响度应该降低约 12 dB。
    func testDuckLowersOnlyThatRange() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        let options = NormalizeOptions(ducks: [VolumeDuck(start: 3, end: 6, gain: -12)])
        let result = try await exporter().export(
            VolumeJob(source: media.appendingPathComponent("loud_loud.mp4"), options: options, outputDirectory: dir))
        let analysis = try await measure(try XCTUnwrap(result.output))
        let inside = momentary(analysis, at: 5)
        let outside = momentary(analysis, at: 8.5)
        XCTAssertEqual(outside - inside, 12, accuracy: 2, "压低段 \(inside)，正常段 \(outside)")
    }

    func testFlattenAndStrongPresetsAndRepairs() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        let source = media.appendingPathComponent("bursts.mp4")
        let before = try await exporter().analyze(source, duration: 30).stats
        for preset in [LoudnessPreset.flatten, .strong] {
            let options = NormalizeOptions(preset: preset, highpass: true, declip: preset == .strong)
            let result = try await exporter().export(VolumeJob(source: source, options: options, outputDirectory: dir))
            let after = try XCTUnwrap(result.after, preset.rawValue)
            XCTAssertEqual(after.integrated, -16, accuracy: 1, preset.rawValue)
            XCTAssertLessThan(after.range, before.range, "\(preset.rawValue) 应该拉平")
        }
        XCTAssertEqual(try outputFiles(), ["bursts_norm.mp4", "bursts_norm_2.mp4"])
    }

    func testOtherContainers() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        let mkv = try await exporter().export(VolumeJob(source: media.appendingPathComponent("sample.mkv"), outputDirectory: dir))
        XCTAssertEqual(mkv.output?.lastPathComponent, "sample_norm.mkv")
        let avi = try await exporter().export(VolumeJob(source: media.appendingPathComponent("sample_mpeg4.avi"), outputDirectory: dir))
        XCTAssertEqual(avi.output?.lastPathComponent, "sample_mpeg4_norm.mkv")
        let sourceHash = try await videoHash(media.appendingPathComponent("sample_mpeg4.avi"))
        let outputHash = try await videoHash(try XCTUnwrap(avi.output))
        XCTAssertEqual(outputHash, sourceHash)
    }

    func testMetadataIsCopied() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        let source = dir.appendingPathComponent("dated.mp4")
        try FileManager.default.copyItem(at: media.appendingPathComponent("loud_medium.mp4"), to: source)
        _ = try await runner.run(try ToolLocator.shared.command(.exiftool, [
            "-q", "-overwrite_original", "-api", "QuickTimeUTC",
            "-QuickTime:CreateDate=2024:05:06 07:08:09+08:00", "-Keys:CreationDate=2024:05:06 07:08:09+08:00", source.path,
        ]))
        let result = try await exporter().export(VolumeJob(source: source, outputDirectory: dir))
        let dates = try await MetadataCopier(runner: runner).readDates(try XCTUnwrap(result.output))
        let sourceDates = try await MetadataCopier(runner: runner).readDates(source)
        XCTAssertFalse(sourceDates.isEmpty)
        XCTAssertTrue(dates.matches(sourceDates), "\(dates) vs \(sourceDates)")
    }

    func testCancellationRemovesPartialOutput() async throws {
        let media = try TestSupport.testMedia()
        try requireNormalizeTools()
        let tmp = FileManager.default.temporaryDirectory
        func workDirs() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.filter { $0.hasPrefix("skimcut-normalize-") } ?? [])
        }
        let existing = workDirs()
        let started = expectation(description: "第二遍开始")
        started.assertForOverFulfill = false
        let exporter = exporter()
        // adeclip 很慢，保证取消时 ffmpeg 还在运行。
        let job = VolumeJob(
            source: media.appendingPathComponent("bursts.mp4"), options: NormalizeOptions(declip: true), outputDirectory: dir)
        let task = Task {
            try await exporter.export(job) { p in
                if let p, p > 0.2 { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 60)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应该被取消")
        } catch is CancellationError {
        } catch {
            XCTFail("应该是 CancellationError：\(error)")
        }
        XCTAssertEqual(try outputFiles(), [], "取消后不留下没完成的文件")
        XCTAssertEqual(workDirs(), existing, "ffmpeg-normalize 的临时目录也删除了")
    }

    // MARK: - 试听

    func testAuditionMatchesWholeFileProcessing() async throws {
        let media = try TestSupport.testMedia()
        let source = media.appendingPathComponent("loud_quiet.mp4")
        let stats = try await exporter().analyze(source, duration: 10).stats
        let options = NormalizeOptions()
        let auditioner = VolumeAuditioner(runner: runner)
        let measured = try await auditioner.measure(source, options: options, stats: stats, duration: 10)
        XCTAssertEqual(measured.integrated, stats.integrated, accuracy: 0.2, "没有前置滤镜时第一遍和检测结果相同")

        let out = dir.appendingPathComponent("audition.m4a")
        try await auditioner.render(source, start: 2, duration: 6, options: options, stats: stats, measured: measured, output: out)
        let info = try await MediaInfo.probe(out, runner: runner)
        XCTAssertEqual(try XCTUnwrap(info.bestDuration), 6, accuracy: 0.1)
        XCTAssertNil(info.videoStream)
        let analysis = try await measure(out)
        XCTAssertEqual(analysis.stats.integrated, -16, accuracy: 1, "试听片段的音量和整个文件处理后一致")
    }

    func testAuditionShiftsDucksToClipTime() async throws {
        let media = try TestSupport.testMedia()
        let source = media.appendingPathComponent("loud_loud.mp4")
        let stats = try await exporter().analyze(source, duration: 10).stats
        let options = NormalizeOptions(ducks: [VolumeDuck(start: 5, end: 7, gain: -12)])
        let auditioner = VolumeAuditioner(runner: runner)
        let measured = try await auditioner.measure(source, options: options, stats: stats, duration: 10)
        let out = dir.appendingPathComponent("duck.m4a")
        // 片段从 3 秒开始：压低段在片段里是 2–4 秒。
        try await auditioner.render(source, start: 3, duration: 6, options: options, stats: stats, measured: measured, output: out)
        let analysis = try await measure(out)
        XCTAssertEqual(momentary(analysis, at: 5.5) - momentary(analysis, at: 3.5), 12, accuracy: 2.5)
    }
}
