import XCTest
@testable import SkimCore

final class TransitionTests: XCTestCase {
    // MARK: - 参数

    func testWindowArgumentsSeekBeforeInputAndOnlyDecodeVideo() {
        let url = URL(fileURLWithPath: "/tmp/a b's.mp4")
        let args = TransitionDetector.arguments(
            input: url, window: 5...11, options: TransitionDetectionOptions(hardwareDecode: false))
        XCTAssertEqual(args, [
            "-hide_banner", "-nostdin", "-nostats",
            "-ss", "5", "-t", "6",
            "-i", "/tmp/a b's.mp4", "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", "scale=160:-2:flags=fast_bilinear,format=gray,blackdetect=d=0.04:pix_th=0.1,scdet=threshold=10",
            "-f", "null", "-",
        ])
    }

    func testWholeFileArgumentsWithProgressAndHardwareDecode() {
        let args = TransitionDetector.arguments(
            input: URL(fileURLWithPath: "/x.mov"), window: nil,
            options: TransitionDetectionOptions(sceneThreshold: 14, hardwareDecode: true), progress: true)
        XCTAssertEqual(Array(args.prefix(7)), ["-hide_banner", "-nostdin", "-progress", "pipe:1", "-nostats", "-hwaccel", "videotoolbox"])
        XCTAssertFalse(args.contains("-ss"))
        XCTAssertTrue(args.contains("scale=160:-2:flags=fast_bilinear,format=gray,blackdetect=d=0.04:pix_th=0.1,scdet=threshold=14"))
        // -hwaccel 是输入选项，必须在 -i 前面。
        XCTAssertLessThan(args.firstIndex(of: "-hwaccel")!, args.firstIndex(of: "-i")!)
    }

    // MARK: - 解析

    func testParseAddsOffsetAndDropsCutsAtBlackEdges() {
        let stderr = """
        [scdet @ 0x55f618dadd80] lavfi.scd.score: 42.429, lavfi.scd.time: 3
        [blackdetect @ 0x7fee9405abc0] black_start:3 black_end:3.5 black_duration:0.5
        [scdet @ 0x55f618dadd80] lavfi.scd.score: 50.348, lavfi.scd.time: 3.5
        frame=  180 fps=0.0 q=-0.0 Lsize=N/A time=00:00:06.00 bitrate=N/A speed=9.6x
        [scdet @ 0x55f618dadd80] lavfi.scd.score: 21.346, lavfi.scd.time: 5.04
        """
        let found = TransitionDetector.parse(stderr, offset: 5)
        XCTAssertEqual(found, [.black(from: 8, to: 8.5), .cut(at: 10.04)])
    }

    func testCombineMergesOverlappingBlacksAndDuplicateCuts() {
        let found = TransitionDetector.combine(cuts: [1.0, 1.01, 6.05, 7.0], blacks: [(4, 5), (4.9, 6), (10, 10.5)])
        // 1.01 和 1.0 是同一个；6.05 是黑屏（4–6）的结束；7.0 是另一个硬切。
        XCTAssertEqual(found, [.cut(at: 1.0), .black(from: 4, to: 6), .cut(at: 7.0), .black(from: 10, to: 10.5)])
    }

    // MARK: - 吸附

    func testDistanceIsZeroInsideBlack() {
        let black = Transition.black(from: 6, to: 6.5)
        XCTAssertEqual(black.distance(to: 6.2), 0)
        XCTAssertEqual(black.distance(to: 5), 1, accuracy: 1e-9)
        XCTAssertEqual(black.distance(to: 7), 0.5, accuracy: 1e-9)
    }

    func testNearestWithinRadius() {
        let list: [Transition] = [.cut(at: 2), .black(from: 6, to: 6.5), .cut(at: 11.5)]
        XCTAssertEqual(TransitionSnapper.nearest(to: 7, in: list, within: 1), .black(from: 6, to: 6.5))
        XCTAssertEqual(TransitionSnapper.nearest(to: 10.8, in: list, within: 1), .cut(at: 11.5))
        XCTAssertNil(TransitionSnapper.nearest(to: 9, in: list, within: 1))
    }

    func testPlayheadSnapsToVisibleFrameNextToBlack() {
        let black = Transition.black(from: 6, to: 6.5)
        // 点在黑屏前面：停在前一段的最后一帧。
        XCTAssertEqual(TransitionSnapper.playheadTime(for: black, clickedAt: 5.8, frameDuration: 0.04), 5.96, accuracy: 1e-9)
        // 点在黑屏后面：停在后一段的第一帧。
        XCTAssertEqual(TransitionSnapper.playheadTime(for: black, clickedAt: 6.9, frameDuration: 0.04), 6.5)
        // 视频开头的黑屏：没有“前一段”，停在黑屏后面。
        let leading = Transition.black(from: 0, to: 1)
        XCTAssertEqual(TransitionSnapper.playheadTime(for: leading, clickedAt: 0, frameDuration: 0.04), 1)
        // 硬切：新画面的第一帧。
        XCTAssertEqual(TransitionSnapper.playheadTime(for: .cut(at: 11.5), clickedAt: 11, frameDuration: 0.04), 11.5)
    }

    func testSearchRadiusFollowsZoom() {
        // 缩小时（1 点 = 2 秒）范围很大，但需要解码时最多 10 秒。
        XCTAssertEqual(TransitionSnapper.searchRadius(secondsPerPixel: 2), 10)
        XCTAssertEqual(TransitionSnapper.searchRadius(secondsPerPixel: 2, maximum: nil), 32)
        // 放大时只找附近一点点。
        XCTAssertEqual(TransitionSnapper.searchRadius(secondsPerPixel: 0.001), 0.25)
        XCTAssertEqual(TransitionSnapper.searchRadius(secondsPerPixel: 0.1), 1.6, accuracy: 1e-9)
    }

    func testAnalysisWindowIsClampedToVideo() {
        XCTAssertEqual(TransitionSnapper.analysisWindow(around: 1, radius: 2, duration: 20), 0...4.5)
        XCTAssertEqual(TransitionSnapper.analysisWindow(around: 19, radius: 2, duration: 20), 15.5...20)
    }

    // MARK: - 缓存

    func testCacheMergesRangesAndTransitions() {
        var cache = TransitionCache()
        cache.insert([.black(from: 5.5, to: 6.0)], covering: 2...6)
        XCTAssertTrue(cache.covers(3...5))
        XCTAssertFalse(cache.covers(5...8))
        cache.insert([.black(from: 5.8, to: 6.5), .cut(at: 9)], covering: 5...10)
        XCTAssertEqual(cache.covered, [2...10])
        XCTAssertTrue(cache.covers(5...8))
        XCTAssertEqual(cache.transitions, [.black(from: 5.5, to: 6.5), .cut(at: 9)])
        XCTAssertFalse(cache.coversWhole(duration: 12))
        cache.insert([], covering: 0...12)
        XCTAssertTrue(cache.coversWhole(duration: 12))
    }

    // MARK: - 分段

    func testSegmentsSkipBlackAndTinyPieces() {
        let list: [Transition] = [.black(from: 0, to: 0.3), .black(from: 6, to: 6.5), .cut(at: 11.5), .black(from: 15.2, to: 15.5)]
        XCTAssertEqual(TransitionSegments.ranges(duration: 15.5, transitions: list), [
            CutRange(start: 0.3, end: 6),
            CutRange(start: 6.5, end: 11.5),
            CutRange(start: 11.5, end: 15.2),
        ])
        XCTAssertEqual(TransitionSegments.ranges(duration: 10, transitions: []), [CutRange(start: 0, end: 10)])
    }

    func testNearestFrameBoundary() {
        let grid = FrameGrid(framesPerSecond: 25)
        XCTAssertEqual(grid.nearestBoundary(6.519), 6.52, accuracy: 1e-9)
        XCTAssertEqual(grid.nearestBoundary(6.501), 6.52, accuracy: 1e-9)
        XCTAssertEqual(grid.nearestBoundary(-1), 0)
    }

    // MARK: - 键盘

    func testNTogglesSnapping() {
        XCTAssertEqual(PlaybackKeyMap.command(keyCode: 45, characters: "n", modifiers: []), .toggleSnapping)
        XCTAssertNil(PlaybackKeyMap.command(keyCode: 45, characters: "n", modifiers: [.shift]))
    }
}

/// 用 joined.mp4（testsrc2 → 6.0–6.52 秒黑屏 → mandelbrot → 11.52 秒硬切 → smptebars）真正运行 ffmpeg。
final class TransitionIntegrationTests: XCTestCase {
    private let duration = 15.5
    /// 拼接时 0.5 秒的黑屏在 25 fps 下变成 13 帧，所以黑屏结束和后面的硬切都晚了一帧。
    private let blackStart = 6.0
    private let blackEnd = 6.52
    private let cut = 11.52
    private let frame = 0.04

    private func media() throws -> URL {
        try TestSupport.testMedia().appendingPathComponent("joined.mp4")
    }

    func testWholeFileFindsBlackAndCut() async throws {
        let url = try media()
        let result = try await TransitionDetector.detect(url, window: nil, duration: duration, options: .fullScan)
        XCTAssertEqual(result.covered, 0...duration)
        XCTAssertEqual(result.transitions.count, 2, "\(result.transitions)")
        let black = try XCTUnwrap(result.transitions.first { $0.kind == .black })
        XCTAssertEqual(black.outPoint, blackStart, accuracy: frame / 2)
        XCTAssertEqual(black.inPoint, blackEnd, accuracy: frame / 2)
        let hard = try XCTUnwrap(result.transitions.first { $0.kind == .cut })
        XCTAssertEqual(hard.inPoint, cut, accuracy: frame / 2)

        let segments = TransitionSegments.ranges(duration: duration, transitions: result.transitions)
        XCTAssertEqual(segments.count, 3)
    }

    func testWindowAroundClickUsesVideoTime() async throws {
        let url = try media()
        let window = TransitionSnapper.analysisWindow(around: 11, radius: 1, duration: duration)
        let result = try await TransitionDetector.detect(url, window: window, duration: duration)
        let found = try XCTUnwrap(TransitionSnapper.nearest(to: 11, in: result.transitions, within: 1))
        XCTAssertEqual(found.kind, .cut)
        XCTAssertEqual(found.inPoint, cut, accuracy: frame / 2)
        // 点击位置附近没有转场。
        let quiet = try await TransitionDetector.detect(
            url, window: TransitionSnapper.analysisWindow(around: 3, radius: 1, duration: duration), duration: duration)
        XCTAssertNil(TransitionSnapper.nearest(to: 3, in: quiet.transitions, within: 1))
    }

    func testWindowStartingInsideBlackIsExtendedToFindTheRealStart() async throws {
        let url = try media()
        // 分析范围从黑屏中间开始：应该自动往前扩，找到真正的黑屏开始。
        let result = try await TransitionDetector.detect(url, window: 6.2...9, duration: duration)
        let black = try XCTUnwrap(result.transitions.first { $0.kind == .black })
        XCTAssertEqual(black.outPoint, blackStart, accuracy: frame / 2)
        XCTAssertEqual(black.inPoint, blackEnd, accuracy: frame / 2)
        XCTAssertLessThan(result.covered.lowerBound, blackStart)
    }
}
