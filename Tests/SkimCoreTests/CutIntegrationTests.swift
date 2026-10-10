import Foundation
import XCTest
@testable import SkimCore

/// 真正运行 ffmpeg / ffprobe / exiftool 的剪切测试。
final class CutIntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())

    private func probe(_ url: URL) async throws -> MediaInfo {
        try await MediaInfo.probe(url, runner: runner)
    }

    /// 每一帧解码后的 MD5（`-f framemd5`）。
    private func frameHashes(_ url: URL) async throws -> [String] {
        try await hashes(url, copy: false)
    }

    /// 每个视频包的 MD5（`-c copy -f framemd5`，证明没有重新编码）。
    private func packetHashes(_ url: URL) async throws -> [String] {
        try await hashes(url, copy: true)
    }

    private func hashes(_ url: URL, copy: Bool) async throws -> [String] {
        var args = ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:v:0"]
        if copy { args += ["-c", "copy"] }
        args += ["-f", "framemd5", "-"]
        return try await runner.output(try ToolLocator.shared.command(.ffmpeg, args))
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") }
            .compactMap { $0.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) }
    }

    /// 输出的第 `outputFrame` 帧和源文件第 `sourceFrame` 帧的 PSNR（dB，完全相同时是 +∞）。
    private func psnr(_ output: URL, frame outputFrame: Int, source: URL, frame sourceFrame: Int) async throws -> Double {
        let graph = "[0:v]trim=start_frame=\(outputFrame):end_frame=\(outputFrame + 1),setpts=PTS-STARTPTS,format=yuv420p[a];"
            + "[1:v]trim=start_frame=\(sourceFrame):end_frame=\(sourceFrame + 1),setpts=PTS-STARTPTS,format=yuv420p[b];"
            + "[a][b]psnr"
        let result = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-i", output.path, "-i", source.path, "-filter_complex", graph, "-f", "null", "-",
        ]))
        let text = result.stderrText
        guard let r = text.range(of: #"average:(inf|[0-9.]+)"#, options: .regularExpression) else {
            throw XCTSkip("读不到 PSNR：\(text.suffix(300))")
        }
        let value = text[r].dropFirst("average:".count)
        return value == "inf" ? .infinity : Double(value) ?? 0
    }

    private func setDates(_ file: URL, _ value: String) async throws {
        _ = try await runner.run(try ToolLocator.shared.command(.exiftool, [
            "-q", "-overwrite_original", "-api", "QuickTimeUTC",
            "-QuickTime:CreateDate=\(value)", "-QuickTime:ModifyDate=\(value)",
            "-Track*Date=\(value)", "-Media*Date=\(value)", "-Keys:CreationDate=\(value)",
            "-ItemList:Title=剪切 测试", file.path,
        ]))
    }

    // MARK: - 快速模式

    func testFastCutStartsAtPreviousKeyframeWithoutReencoding() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.exiftool)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 带空格和引号的文件名。
        let source = dir.appendingPathComponent("源 'a' \"b\".mp4")
        try FileManager.default.copyItem(at: media.appendingPathComponent("h264_gop4.mp4"), to: source)
        let info = try await probe(source)

        let exporter = CutExporter(runner: runner, encoder: .software(lossless: false))
        let plan = try await exporter.plan(
            source: source, info: info, range: CutRange(start: 5, end: 7), options: CutOptions(mode: .fast))
        XCTAssertEqual(plan.actualStart, 4, accuracy: 0.001, "关键帧每 4 秒一个")
        XCTAssertEqual(plan.leadIn, 1, accuracy: 0.001)
        XCTAssertEqual(plan.output.lastPathComponent, "源 'a' \"b\"_cut_00m05.000s-00m07.000s.mp4")
        XCTAssertEqual(plan.leadInMessage, "实际起点会提前 1.000 秒（从 00:00:04.000 开始，那里是最近的关键帧）。")

        let progress = LockedBox<[Double]>([])
        let result = try await exporter.export(plan) { p in if let p { progress.mutate { $0.append(p) } } }
        XCTAssertEqual(progress.value.last, 1)

        let out = try await probe(result.output)
        XCTAssertEqual(try XCTUnwrap(out.videoStream?.codecName), "h264")
        XCTAssertEqual(out.audioStreams.first?.codecName, "aac")

        // 视频没有重新编码：输出的包就是源文件从第 4 秒（第 120 帧）开始的那些包。
        let src = try await packetHashes(source)
        let cut = try await packetHashes(result.output)
        // 4.0–7.0 秒是 90 帧；复制模式按解码顺序截断，有 B 帧时终点会多带 1–3 帧。
        XCTAssertTrue((90...93).contains(cut.count), "帧数 \(cut.count)")
        XCTAssertEqual(cut, Array(src[120..<(120 + cut.count)]))

        // 原文件没有被修改。
        let original = try await packetHashes(media.appendingPathComponent("h264_gop4.mp4"))
        XCTAssertEqual(src, original)
    }

    func testFastCutFromMKVProducesMP4() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("sample.mkv")
        let info = try await probe(source)
        let exporter = CutExporter(runner: runner)
        let plan = try await exporter.plan(
            source: source, info: info, range: CutRange(start: 2.5, end: 5),
            options: CutOptions(mode: .fast, outputDirectory: dir))
        XCTAssertEqual(plan.output.pathExtension, "mp4")
        XCTAssertEqual(plan.output.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertFalse(plan.copiesMetadata, "MKV 源不复制元数据（ExifTool 只写 MP4/MOV）")
        XCTAssertEqual(plan.actualStart, 2, accuracy: 0.03, "sample.mkv 每 2 秒一个关键帧")
        let result = try await exporter.export(plan)
        let out = try await probe(result.output)
        XCTAssertTrue(out.isQuickTimeFamily)
        XCTAssertEqual(try XCTUnwrap(out.bestDuration), 3, accuracy: 0.25, "2.0–5.0 秒，终点可能多几帧")
    }

    // MARK: - 精确模式（M2 验收）

    /// 精确模式导出的第一帧和指定时间的源帧一致（用 framemd5 验证；测试用无损编码，误差 ≤ 1 帧）。
    func testPreciseCutIsFrameAccurate() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let info = try await probe(source)
        let exporter = CutExporter(runner: runner, encoder: .software(lossless: true))
        // 5.5 秒不是关键帧（关键帧在 4 和 8 秒）。
        let plan = try await exporter.plan(
            source: source, info: info, range: CutRange(start: 5.5, end: 7.5),
            options: CutOptions(mode: .precise, outputDirectory: dir))
        XCTAssertEqual(plan.actualStart, 5.5)
        let result = try await exporter.export(plan)

        let src = try await frameHashes(source)
        let cut = try await frameHashes(result.output)
        XCTAssertEqual(cut.count, 60, "2 秒 × 30 fps")
        let expectedFirst = 165  // 5.5 × 30
        let first = try XCTUnwrap(src.firstIndex(of: cut[0]), "第一帧在源文件里找不到")
        XCTAssertLessThanOrEqual(abs(first - expectedFirst), 1, "第一帧是源文件第 \(first) 帧")
        XCTAssertEqual(first, expectedFirst)
        let last = try XCTUnwrap(src.firstIndex(of: cut[cut.count - 1]))
        XCTAssertEqual(last, expectedFirst + 59)
    }

    func testPrecise10BitHEVCKeepsMain10AndColor() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("hevc_10bit.mp4")
        let info = try await probe(source)
        let exporter = CutExporter(runner: runner, encoder: .software(lossless: true))
        let plan = try await exporter.plan(
            source: source, info: info, range: CutRange(start: 1.5, end: 2.5),
            options: CutOptions(mode: .precise, outputDirectory: dir))
        let result = try await exporter.export(plan)
        let probed = try await probe(result.output)
        let v = try XCTUnwrap(probed.videoStream)
        XCTAssertEqual(v.codecName, "hevc")
        XCTAssertEqual(v.codecTagString, "hvc1")
        XCTAssertEqual(v.pixelFormat, "yuv420p10le")
        XCTAssertEqual(v.profile, "Main 10")
        XCTAssertEqual(v.colorPrimaries, "bt709")
        XCTAssertEqual(v.colorTransfer, "bt709")
        XCTAssertEqual(v.colorSpace, "bt709")

        let src = try await frameHashes(source)
        let cut = try await frameHashes(result.output)
        XCTAssertEqual(cut.count, 30)
        XCTAssertEqual(src.firstIndex(of: cut[0]), 45, "1.5 × 30")
    }

    /// 有损编码（macOS 上是 VideoToolbox）：MD5 不可能相同，改用 PSNR 判断第一帧最像源文件的哪一帧。
    func testLossyPreciseCutFirstFrameMatchesByPSNR() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let info = try await probe(source)
        #if os(macOS)
        let exporter = CutExporter(runner: runner, encoder: .videoToolbox)
        #else
        let exporter = CutExporter(runner: runner, encoder: .software(lossless: false))
        #endif
        let plan = try await exporter.plan(
            source: source, info: info, range: CutRange(start: 5.5, end: 6.5),
            options: CutOptions(mode: .precise, outputDirectory: dir))
        let result: CutResult
        do {
            result = try await exporter.export(plan)
        } catch let error as ToolError where ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("CI 虚拟机里编码器不可用：\(error.errorDescription ?? "")")
        }
        var scores: [Int: Double] = [:]
        for candidate in 163...167 {
            scores[candidate] = try await psnr(result.output, frame: 0, source: source, frame: candidate)
        }
        let best = try XCTUnwrap(scores.max { $0.value < $1.value }?.key)
        XCTAssertLessThanOrEqual(abs(best - 165), 1, "PSNR：\(scores.sorted { $0.key < $1.key })")
        let frames = try await frameHashes(result.output)
        XCTAssertEqual(frames.count, 30)
    }

    // MARK: - 元数据

    func testMetadataIsCopiedAndRecordingDateShifted() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.exiftool)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("dated.mp4")
        try FileManager.default.copyItem(at: media.appendingPathComponent("h264_gop4.mp4"), to: source)
        try await setDates(source, "2026:10:09 14:00:00+08:00")

        let info = try await probe(source)
        let exporter = CutExporter(runner: runner, encoder: .software(lossless: false))

        // 精确模式：录制时间 + 5.5 秒（QuickTime 日期只到秒，四舍五入成 +6）。
        let precise = try await exporter.export(try await exporter.plan(
            source: source, info: info, range: CutRange(start: 5.5, end: 6.5), options: CutOptions(mode: .precise)))
        let dates = try await MetadataCopier(runner: runner).readDates(precise.output)
        XCTAssertEqual(dates.keysCreationDate?.exifToolString, "2026:10:09 14:00:06+08:00")
        XCTAssertEqual(dates.createDate.map { Int($0.date.timeIntervalSince1970) }, 1_791_525_606)

        let title = try await runner.output(try ToolLocator.shared.command(.exiftool, ["-s3", "-ItemList:Title", precise.output.path]))
        XCTAssertEqual(title.trimmingCharacters(in: .whitespacesAndNewlines), "剪切 测试")
        // 时长没有被复制成源文件的 20 秒。
        let preciseInfo = try await probe(precise.output)
        XCTAssertEqual(try XCTUnwrap(preciseInfo.bestDuration), 1, accuracy: 0.1)

        // 快速模式：按实际起点（关键帧 4 秒）平移。
        let fast = try await exporter.export(try await exporter.plan(
            source: source, info: info, range: CutRange(start: 5, end: 6), options: CutOptions(mode: .fast)))
        let fastDates = try await MetadataCopier(runner: runner).readDates(fast.output)
        XCTAssertEqual(fastDates.keysCreationDate?.exifToolString, "2026:10:09 14:00:04+08:00")

        // 关掉平移：和源文件相同。
        let same = try await exporter.export(try await exporter.plan(
            source: source, info: info, range: CutRange(start: 5, end: 6),
            options: CutOptions(mode: .fast, shiftRecordingDate: false)))
        XCTAssertTrue(same.output.lastPathComponent.hasSuffix("_2.mp4"), "重名自动加序号：\(same.output.lastPathComponent)")
        let sameDates = try await MetadataCopier(runner: runner).readDates(same.output)
        XCTAssertEqual(sameDates.keysCreationDate?.exifToolString, "2026:10:09 14:00:00+08:00")

        // 原文件的日期没有变。
        let srcDates = try await MetadataCopier(runner: runner).readDates(source)
        XCTAssertEqual(srcDates.keysCreationDate?.exifToolString, "2026:10:09 14:00:00+08:00")
    }

    func testSourceWithoutDatesStillCopiesAndVerifies() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.exiftool)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let exporter = CutExporter(runner: runner)
        let result = try await exporter.export(try await exporter.plan(
            source: source, info: try await probe(source), range: CutRange(start: 8, end: 9),
            options: CutOptions(mode: .fast, outputDirectory: dir)))
        XCTAssertEqual(result.recordingDates, RecordingDates())
    }

    // MARK: - 取消

    func testCancelRemovesPartialOutput() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let exporter = CutExporter(runner: runner, encoder: .software(lossless: false))
        let plan = try await exporter.plan(
            source: source, info: try await probe(source), range: CutRange(start: 0, end: 20),
            options: CutOptions(mode: .precise, outputDirectory: dir))
        let started = LockedBox(false)
        let task = Task { try await exporter.export(plan) { _ in started.set(true) } }
        try await waitFor(timeout: 20) { started.value }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.output.path))
        }
    }
}
