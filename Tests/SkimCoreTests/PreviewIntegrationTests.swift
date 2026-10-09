import Foundation
import XCTest
@testable import SkimCore

/// 真正运行 ffmpeg / ffprobe 的预览测试。
final class PreviewIntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())

    private func probe(_ url: URL) async throws -> MediaInfo {
        try await MediaInfo.probe(url, runner: runner)
    }

    /// 视频流每个包的 MD5（只取哈希列，不比较时间戳）。
    private func videoPacketHashes(_ url: URL) async throws -> [String] {
        let cmd = try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", url.path,
            "-map", "0:v:0", "-c", "copy", "-f", "framemd5", "-",
        ])
        return try await runner.output(cmd)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") }
            .compactMap { $0.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) }
    }

    private func keyframeTimes(_ url: URL) async throws -> [Double] {
        let cmd = try ToolLocator.shared.command(.ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
            "-show_entries", "frame=pts_time", "-of", "csv=p=0", url.path,
        ])
        return try await runner.output(cmd)
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
    }

    func testProbeTestMedia() async throws {
        let media = try TestSupport.testMedia()

        let h264 = try await probe(media.appendingPathComponent("h264_gop4.mp4"))
        XCTAssertTrue(h264.isQuickTimeFamily)
        XCTAssertEqual(try XCTUnwrap(h264.bestDuration), 20, accuracy: 0.1)
        XCTAssertEqual(h264.videoStream?.codecName, "h264")
        XCTAssertEqual(h264.videoStream?.width, 1280)
        XCTAssertEqual(try XCTUnwrap(h264.videoStream?.frameRate), 30, accuracy: 0.01)
        XCTAssertEqual(h264.audioStreams.first?.codecName, "aac")
        XCTAssertTrue(PreviewPlanner.guessNativelyPlayable(h264))

        let hevc = try await probe(media.appendingPathComponent("hevc_10bit.mp4"))
        XCTAssertEqual(hevc.videoStream?.codecTagString, "hvc1")
        XCTAssertEqual(hevc.videoStream?.isHighBitDepth, true)
        XCTAssertEqual(hevc.videoStream?.colorTransfer, "bt709")

        let mkv = try await probe(media.appendingPathComponent("sample.mkv"))
        XCTAssertEqual(try PreviewPlanner.strategy(for: mkv, nativelyPlayable: false), .remux)

        let avi = try await probe(media.appendingPathComponent("sample_mpeg4.avi"))
        XCTAssertEqual(avi.formatName, "avi")
        XCTAssertEqual(avi.videoStream?.codecName, "mpeg4")
        XCTAssertEqual(try PreviewPlanner.strategy(for: avi, nativelyPlayable: false), .proxy)
    }

    func testProbeNonMediaFails() async throws {
        _ = try TestSupport.requireTool(.ffprobe)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("not a video.mp4")
        try Data("hello".utf8).write(to: bogus)
        do {
            _ = try await probe(bogus)
            XCTFail("应该失败")
        } catch let error as ToolError {
            XCTAssertNotNil(error.fullLog)
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testRemuxMKVCopiesVideoStream() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("sample.mkv")
        let info = try await probe(source)
        let out = dir.appendingPathComponent("预览 'remux'.mp4")

        let progress = LockedBox<[Double]>([])
        try await PreviewBuilder(runner: runner, encoder: .libx264)
            .build(source: source, info: info, strategy: .remux, output: out) { p in
                if let p { progress.mutate { $0.append(p) } }
            }
        XCTAssertEqual(progress.value.last, 1)

        let result = try await probe(out)
        XCTAssertTrue(result.isQuickTimeFamily)
        XCTAssertEqual(result.videoStream?.codecName, "h264")
        XCTAssertEqual(result.audioStreams.first?.codecName, "aac")
        XCTAssertEqual(try XCTUnwrap(result.bestDuration), 8, accuracy: 0.1)
        XCTAssertTrue(PreviewPlanner.guessNativelyPlayable(result))

        // 视频没有重新编码：每个包的内容完全相同。
        let a = try await videoPacketHashes(source)
        let b = try await videoPacketHashes(out)
        XCTAssertEqual(a.count, 200)
        XCTAssertEqual(a, b)
    }

    func testRemuxHEVCInMKVGetsHvc1Tag() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = dir.appendingPathComponent("hevc.mkv")
        _ = try await runner.run(try ToolLocator.shared.command(.ffmpeg, [
            "-hide_banner", "-nostdin", "-v", "error", "-i", media.appendingPathComponent("hevc_10bit.mp4").path,
            "-c", "copy", mkv.path,
        ]))
        let info = try await probe(mkv)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info, nativelyPlayable: false), .remux)

        let out = dir.appendingPathComponent("hevc-preview.mp4")
        try await PreviewBuilder(runner: runner).build(source: mkv, info: info, strategy: .remux, output: out)
        let result = try await probe(out)
        XCTAssertEqual(result.videoStream?.codecName, "hevc")
        XCTAssertEqual(result.videoStream?.codecTagString, "hvc1")
        XCTAssertEqual(result.videoStream?.pixelFormat, "yuv420p10le")
        let hashesIn = try await videoPacketHashes(mkv)
        let hashesOut = try await videoPacketHashes(out)
        XCTAssertEqual(hashesIn, hashesOut)
    }

    func testProxyFromAVIWithLibx264() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("sample_mpeg4.avi")
        let info = try await probe(source)
        let out = dir.appendingPathComponent("proxy.mp4")
        try await PreviewBuilder(runner: runner, encoder: .libx264)
            .build(source: source, info: info, strategy: .proxy, output: out)

        let result = try await probe(out)
        let v = try XCTUnwrap(result.videoStream)
        XCTAssertEqual(v.codecName, "h264")
        XCTAssertEqual(v.pixelFormat, "yuv420p")
        XCTAssertEqual(v.height, 360, "不放大")
        XCTAssertEqual(result.audioStreams.first?.codecName, "aac")
        XCTAssertEqual(try XCTUnwrap(result.bestDuration), 6, accuracy: 0.1)
        XCTAssertTrue(PreviewPlanner.guessNativelyPlayable(result))

        // GOP 约 0.5 秒（25 fps → 13 帧）。
        let keys = try await keyframeTimes(out)
        XCTAssertGreaterThanOrEqual(keys.count, 11)
        for (a, b) in zip(keys, keys.dropFirst()) {
            XCTAssertLessThanOrEqual(b - a, 0.55)
        }
    }

    func testProxyDownscalesTo540() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("hevc_10bit.mp4")
        let info = try await probe(source)
        let out = dir.appendingPathComponent("proxy.mp4")
        try await PreviewBuilder(runner: runner, encoder: .libx264)
            .build(source: source, info: info, strategy: .proxy, output: out)
        let probed = try await probe(out)
        let v = try XCTUnwrap(probed.videoStream)
        XCTAssertEqual(v.width, 960)
        XCTAssertEqual(v.height, 540)
        XCTAssertEqual(v.pixelFormat, "yuv420p", "10-bit 源也输出 8-bit 代理")
    }

    func testCancelledPreviewRemovesPartialFile() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("h264_gop4.mp4")
        let info = try await probe(source)
        let out = dir.appendingPathComponent("cancelled.mp4")
        let started = LockedBox(false)
        let builder = PreviewBuilder(runner: runner, encoder: .libx264)
        let task = Task {
            try await builder
                .build(source: source, info: info, strategy: .proxy, output: out) { _ in started.set(true) }
        }
        try await waitFor(timeout: 20) { started.value }
        task.cancel()
        do {
            try await task.value
            // 机器很快时可能在取消之前就完成了；那样就不检查半成品。
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    #if os(macOS)
    /// macOS 上用 VideoToolbox 生成代理。GitHub 的 macOS 虚拟机里可能没有可用的编码器，那时只在 CI 上跳过。
    func testProxyWithVideoToolbox() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = media.appendingPathComponent("sample_mpeg4.avi")
        let info = try await probe(source)
        let out = dir.appendingPathComponent("vt.mp4")
        do {
            try await PreviewBuilder(runner: runner, encoder: .videoToolbox)
                .build(source: source, info: info, strategy: .proxy, output: out)
        } catch let error as ToolError where ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("CI 虚拟机里 VideoToolbox 不可用：\(error.errorDescription ?? "")")
        }
        let probed = try await probe(out)
        let v = try XCTUnwrap(probed.videoStream)
        XCTAssertEqual(v.codecName, "h264")
        XCTAssertEqual(v.height, 360)
    }
    #endif
}
