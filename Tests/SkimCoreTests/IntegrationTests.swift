import Foundation
import XCTest
@testable import SkimCore

/// 真正运行 ffmpeg、ffprobe、exiftool 等工具的集成测试。
/// 本地缺工具时跳过；CI 设置 SKIMCUT_REQUIRE_TOOLS=1，缺工具就失败。
final class IntegrationTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())

    func testEveryToolIsFoundAndReportsAVersion() async throws {
        for tool in Tool.allCases { _ = try TestSupport.requireTool(tool) }
        let statuses = await ToolInventory.check(runner: runner)
        for status in statuses {
            XCTAssertNotNil(status.path, "\(status.tool.rawValue) 未找到")
            // macOS 14 起系统自带的 iconv 不一定支持 --version，只要求能找到。
            if status.tool != .iconv {
                XCTAssertNotNil(status.version, "\(status.tool.rawValue) 读不到版本号")
            }
        }
    }

    func testFFmpegNormalizeRunsWithFFmpegPath() async throws {
        _ = try TestSupport.requireTool(.ffmpeg)
        _ = try TestSupport.requireTool(.ffmpegNormalize)
        let cmd = try ToolLocator.shared.command(.ffmpegNormalize, ["--version"])
        XCTAssertNotNil(cmd.environment["FFMPEG_PATH"])
        let out = try await runner.output(cmd)
        XCTAssertNotNil(Tool.parseVersion(out))
    }

    func testTestMediaHasKeyframesEvery4Seconds() async throws {
        let media = try TestSupport.testMedia()
        let cmd = try ToolLocator.shared.command(.ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
            "-show_entries", "frame=pts_time", "-of", "csv=p=0",
            media.appendingPathComponent("h264_gop4.mp4").path,
        ])
        let times = try await runner.output(cmd)
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
        XCTAssertEqual(times.count, 5)
        for (i, t) in times.enumerated() { XCTAssertEqual(t, Double(i) * 4, accuracy: 0.05) }
    }

    func testTestMediaHas10BitHEVC() async throws {
        let media = try TestSupport.testMedia()
        let cmd = try ToolLocator.shared.command(.ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,pix_fmt,codec_tag_string", "-of", "json",
            media.appendingPathComponent("hevc_10bit.mp4").path,
        ])
        let json = try JSONSerialization.jsonObject(with: try await runner.run(cmd).stdout) as? [String: Any]
        let stream = try XCTUnwrap((json?["streams"] as? [[String: Any]])?.first)
        XCTAssertEqual(stream["codec_name"] as? String, "hevc")
        XCTAssertEqual(stream["pix_fmt"] as? String, "yuv420p10le")
        XCTAssertEqual(stream["codec_tag_string"] as? String, "hvc1")
    }

    func testFFmpegProgressAndCancellation() async throws {
        let media = try TestSupport.testMedia()
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. 正常运行：收到进度，最后一个快照是 progress=end。
        let out = dir.appendingPathComponent("输出 文件.mp4")
        let snapshots = LockedBox<[FFmpegProgress]>([])
        let parser = LockedBox(FFmpegProgressParser())
        let cmd = try ToolLocator.shared.command(.ffmpeg, ["-hide_banner", "-nostdin", "-y"]
            + FFmpegProgress.arguments
            + ["-i", media.appendingPathComponent("sample.mkv").path,
               "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart", out.path])
        _ = try await runner.run(cmd, partialOutputs: [out], onStdoutLine: { line in
            var p = parser.value
            if let snap = p.consume(line: line) { snapshots.mutate { $0.append(snap) } }
            parser.set(p)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(snapshots.value.last?.isEnd, true)
        XCTAssertEqual(snapshots.value.last?.outTime ?? 0, 8, accuracy: 0.2)

        // 2. 一个很慢的编码任务（-re 按实时速度读取），开始后取消：进程结束、半成品删除。
        let registry = ProcessRegistry()
        let slowRunner = ToolRunner(registry: registry)
        let slowOut = dir.appendingPathComponent("slow.mp4")
        let slow = try ToolLocator.shared.command(.ffmpeg, ["-hide_banner", "-nostdin", "-y"]
            + FFmpegProgress.arguments
            + ["-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=600",
               "-c:v", "libx264", "-preset", "ultrafast", slowOut.path])
        let gotProgress = LockedBox(false)
        let task = Task {
            try await slowRunner.run(slow, partialOutputs: [slowOut], onStdoutLine: { line in
                if line.hasPrefix("progress=") { gotProgress.set(true) }
            })
        }
        try await waitFor(timeout: 20) { gotProgress.value }
        let pid = try XCTUnwrap(registry.activePIDs.first)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应该被取消")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: slowOut.path))
        XCTAssertFalse(ProcessKiller.isAlive(pid))
    }

    func testSubtitleEncodingDetectionAndConversion() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.uchardet)
        let srt = media.appendingPathComponent("subs_gbk.srt")
        let detected = try await runner.output(try ToolLocator.shared.command(.uchardet, [srt.path]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(["GB18030", "GBK", "GB2312"].contains(detected.uppercased()), detected)
        XCTAssertNil(String(data: try Data(contentsOf: srt), encoding: .utf8), "测试文件不应该是 UTF-8")

        let utf8 = try await runner.output(try ToolLocator.shared.command(.iconv, ["-f", detected, "-t", "UTF-8", srt.path]))
        XCTAssertTrue(utf8.contains("你好，世界！"))
    }

    func testExiftoolReadsMetadataAsJSON() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.exiftool)
        let cmd = try ToolLocator.shared.command(.exiftool, [
            "-j", "-G1", "-a", "-s", "-api", "QuickTimeUTC", media.appendingPathComponent("h264_gop4.mp4").path,
        ])
        let json = try JSONSerialization.jsonObject(with: try await runner.run(cmd).stdout) as? [[String: Any]]
        let first = try XCTUnwrap(json?.first)
        XCTAssertNotNil(first["QuickTime:Duration"] ?? first["Track1:Duration"])
    }

    func testMkvpropeditCanSetTitle() async throws {
        let media = try TestSupport.testMedia()
        _ = try TestSupport.requireTool(.mkvpropedit)
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("copy.mkv")
        try FileManager.default.copyItem(at: media.appendingPathComponent("sample.mkv"), to: copy)
        // 在 C locale 下也要能写入中文（ToolLocator 会设置 LC_ALL）。
        _ = try await runner.run(try ToolLocator.shared.command(.mkvpropedit, [copy.path, "--edit", "info", "--set", "title=测试 标题"]))
        let probe = try await runner.output(try ToolLocator.shared.command(.ffprobe, [
            "-v", "error", "-show_entries", "format_tags=title", "-of", "csv=p=0", copy.path,
        ]))
        XCTAssertEqual(probe.trimmingCharacters(in: .whitespacesAndNewlines), "测试 标题")
    }
}
