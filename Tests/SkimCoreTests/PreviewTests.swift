import Foundation
import XCTest
@testable import SkimCore

final class MediaInfoTests: XCTestCase {
    static let mkvJSON = """
    {
      "streams": [
        {"index": 0, "codec_name": "h264", "profile": "High", "codec_type": "video",
         "codec_tag_string": "[0][0][0][0]", "width": 640, "height": 360, "pix_fmt": "yuv420p",
         "r_frame_rate": "25/1", "avg_frame_rate": "25/1",
         "disposition": {"default": 1, "attached_pic": 0}},
        {"index": 1, "codec_name": "aac", "codec_type": "audio", "r_frame_rate": "0/0",
         "avg_frame_rate": "0/0", "tags": {"language": "jpn"}},
        {"index": 2, "codec_name": "mjpeg", "codec_type": "video", "width": 300, "height": 300,
         "disposition": {"attached_pic": 1}},
        {"index": 3, "codec_name": "subrip", "codec_type": "subtitle"}
      ],
      "format": {"format_name": "matroska,webm", "duration": "8.021000"}
    }
    """

    func testParse() throws {
        let info = try MediaInfo.parse(Data(Self.mkvJSON.utf8))
        XCTAssertEqual(info.formatName, "matroska,webm")
        XCTAssertEqual(try XCTUnwrap(info.duration), 8.021, accuracy: 1e-9)
        XCTAssertEqual(info.streams.count, 4)
        let v = try XCTUnwrap(info.videoStream)
        XCTAssertEqual(v.index, 0)
        XCTAssertEqual(v.codecName, "h264")
        XCTAssertEqual(v.width, 640)
        XCTAssertEqual(v.frameRate, 25)
        XCTAssertFalse(v.isHighBitDepth)
        XCTAssertEqual(info.audioStreams.map(\.language), ["jpn"])
        XCTAssertTrue(info.streams[2].isAttachedPicture)
        XCTAssertFalse(info.streams[2].isVideo, "封面图不算视频流")
        XCTAssertFalse(info.isQuickTimeFamily)
    }

    func testRateParsing() {
        XCTAssertEqual(try XCTUnwrap(MediaInfo.parseRate("30000/1001")), 29.97, accuracy: 0.001)
        XCTAssertNil(MediaInfo.parseRate("0/0"))
        XCTAssertNil(MediaInfo.parseRate(nil))
        XCTAssertEqual(MediaInfo.parseRate("24"), 24)
    }

    func testBitDepthAndHDR() {
        func stream(_ fmt: String, trc: String? = nil) -> MediaStream {
            MediaStream(index: 0, codecType: "video", pixelFormat: fmt, colorTransfer: trc)
        }
        XCTAssertTrue(stream("yuv420p10le").isHighBitDepth)
        XCTAssertTrue(stream("p010le").isHighBitDepth)
        XCTAssertTrue(stream("yuv422p12be").isHighBitDepth)
        XCTAssertFalse(stream("yuv420p").isHighBitDepth)
        XCTAssertFalse(stream("yuv410p").isHighBitDepth)
        XCTAssertTrue(stream("yuv420p10le", trc: "smpte2084").isHDR)
        XCTAssertTrue(stream("yuv420p10le", trc: "arib-std-b67").isHDR)
        XCTAssertFalse(stream("yuv420p10le", trc: "bt709").isHDR)
    }

    func testBestDurationFallsBackToStreams() {
        let info = MediaInfo(formatName: "avi", duration: nil, streams: [
            MediaStream(index: 0, codecType: "video", duration: 5),
            MediaStream(index: 1, codecType: "audio", duration: 5.2),
        ])
        XCTAssertEqual(info.bestDuration, 5.2)
    }

    func testNotJSON() {
        XCTAssertThrowsError(try MediaInfo.parse(Data("oops".utf8)))
    }

    func testProbeArguments() {
        let url = URL(fileURLWithPath: "/tmp/带 空格's \"file\".mkv")
        XCTAssertEqual(MediaInfo.probeArguments(for: url),
                       ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
    }
}

final class PreviewPlannerTests: XCTestCase {
    private func info(container: String = "matroska,webm", video: String?, pix: String = "yuv420p",
                      tag: String? = nil, audio: String? = "aac", fps: Double = 25) -> MediaInfo {
        var streams: [MediaStream] = []
        if let video {
            streams.append(MediaStream(index: 0, codecType: "video", codecName: video, codecTagString: tag,
                                       width: 1920, height: 1080, pixelFormat: pix, frameRate: fps))
        }
        if let audio {
            streams.append(MediaStream(index: streams.count, codecType: "audio", codecName: audio))
        }
        return MediaInfo(formatName: container, duration: 10, streams: streams)
    }

    func testStrategyTable() throws {
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "h264"), nativelyPlayable: true), .native)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "h264"), nativelyPlayable: false), .remux)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "hevc", pix: "yuv420p10le"), nativelyPlayable: false), .remux)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "h264", audio: nil), nativelyPlayable: false), .remux)
        // 不是 AAC 的音频、其他视频编码、H.264 10-bit、4:2:2：都要生成代理。
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "h264", audio: "opus"), nativelyPlayable: false), .proxy)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "vp9"), nativelyPlayable: false), .proxy)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "mpeg4", audio: "mp2"), nativelyPlayable: false), .proxy)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "h264", pix: "yuv420p10le"), nativelyPlayable: false), .proxy)
        XCTAssertEqual(try PreviewPlanner.strategy(for: info(video: "hevc", pix: "yuv422p10le"), nativelyPlayable: false), .proxy)
        XCTAssertThrowsError(try PreviewPlanner.strategy(for: info(video: nil), nativelyPlayable: true)) { error in
            XCTAssertEqual(error as? PreviewError, .noVideoStream)
        }
    }

    func testGuessNativelyPlayable() {
        let mp4 = "mov,mp4,m4a,3gp,3g2,mj2"
        XCTAssertTrue(PreviewPlanner.guessNativelyPlayable(info(container: mp4, video: "h264")))
        XCTAssertTrue(PreviewPlanner.guessNativelyPlayable(info(container: mp4, video: "hevc", tag: "hvc1")))
        XCTAssertFalse(PreviewPlanner.guessNativelyPlayable(info(container: mp4, video: "hevc", tag: "hev1")))
        XCTAssertFalse(PreviewPlanner.guessNativelyPlayable(info(video: "h264")))
        XCTAssertFalse(PreviewPlanner.guessNativelyPlayable(info(container: mp4, video: "h264", audio: "opus")))
    }

    func testRemuxArguments() {
        let input = URL(fileURLWithPath: "/Volumes/视频/a b's \"clip\".mkv")
        let output = URL(fileURLWithPath: "/tmp/out dir/p.mp4")
        let args = PreviewPlanner.remuxArguments(input: input, output: output, info: info(video: "h264"))
        XCTAssertEqual(args, [
            "-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats",
            "-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
            "-sn", "-dn", "-movflags", "+faststart", "-f", "mp4", output.path,
        ])
    }

    func testRemuxHEVCAddsHvc1Tag() {
        let args = PreviewPlanner.remuxArguments(
            input: URL(fileURLWithPath: "/a.mkv"), output: URL(fileURLWithPath: "/b.mp4"),
            info: info(video: "hevc", pix: "yuv420p10le"))
        let i = args.firstIndex(of: "-tag:v")
        XCTAssertNotNil(i)
        XCTAssertEqual(args[i! + 1], "hvc1")
    }

    func testProxyArguments() {
        let input = URL(fileURLWithPath: "/in.avi")
        let output = URL(fileURLWithPath: "/out.mp4")
        let vt = PreviewPlanner.proxyArguments(input: input, output: output, info: info(video: "mpeg4", fps: 30), encoder: .videoToolbox)
        XCTAssertTrue(vt.contains("h264_videotoolbox"))
        XCTAssertEqual(vt[vt.firstIndex(of: "-g")! + 1], "15")
        XCTAssertEqual(vt[vt.firstIndex(of: "-vf")! + 1], "scale=w=-2:h='min(540,trunc(ih/2)*2)',format=yuv420p")
        XCTAssertEqual(vt.last, output.path)
        XCTAssertEqual(Array(vt[3...5]), FFmpegProgress.arguments)

        let x264 = PreviewPlanner.proxyArguments(input: input, output: output, info: info(video: "mpeg4", fps: 25), encoder: .libx264)
        XCTAssertTrue(x264.contains("libx264"))
        XCTAssertFalse(x264.contains("h264_videotoolbox"))
        XCTAssertEqual(x264[x264.firstIndex(of: "-g")! + 1], "13")
    }

    func testNativeHasNoArguments() {
        XCTAssertNil(PreviewPlanner.arguments(
            strategy: .native, input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
            info: info(video: "h264"), encoder: .libx264))
    }
}

final class PreviewFileStoreTests: XCTestCase {
    func testSessionDirectoryLifecycle() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreviewFileStore(root: root, processID: 4242)
        XCTAssertTrue(store.sessionDirectory.lastPathComponent.hasPrefix("session-4242-"))

        let url = try store.makePreviewURL(for: URL(fileURLWithPath: "/x/我的 视频.mkv"), strategy: .remux)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, store.sessionDirectory.standardizedFileURL)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("我的 视频-remux-"))
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "只分配路径，不创建文件")

        try Data("x".utf8).write(to: url)
        store.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try Data("y".utf8).write(to: try store.makePreviewURL(for: URL(fileURLWithPath: "/x/a.avi"), strategy: .proxy))
        store.removeSessionDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionDirectory.path))
    }

    func testPurgeStaleRemovesOnlyDeadSessions() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for name in ["session-111-aaaa", "session-222-bbbb", "unrelated", "session-x-cccc"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let removed = PreviewFileStore.purgeStale(root: root) { $0 == 222 }
        XCTAssertEqual(removed.map(\.lastPathComponent), ["session-111-aaaa"])
        let left = try fm.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(left, ["session-222-bbbb", "session-x-cccc", "unrelated"])
    }

    func testPurgeStaleKeepsCurrentProcess() throws {
        let root = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PreviewFileStore(root: root)
        _ = try store.makePreviewURL(for: URL(fileURLWithPath: "/a.mkv"), strategy: .remux)
        XCTAssertEqual(PreviewFileStore.purgeStale(root: root), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionDirectory.path))
    }
}
