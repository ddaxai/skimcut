import XCTest
@testable import SkimCore

final class TimelineGeometryTests: XCTestCase {
    func testStartsFitted() {
        let g = TimelineGeometry(duration: 100, viewWidth: 1000)
        XCTAssertEqual(g.pixelsPerSecond, 10)
        XCTAssertEqual(g.visibleRange, 0...100)
        XCTAssertTrue(g.isFitted)
        XCTAssertEqual(g.x(for: 50), 500)
        XCTAssertEqual(g.time(at: 250), 25)
    }

    func testTimeIsClamped() {
        let g = TimelineGeometry(duration: 100, viewWidth: 1000)
        XCTAssertEqual(g.time(at: -50), 0)
        XCTAssertEqual(g.time(at: 5000), 100)
    }

    func testZoomKeepsTimeUnderAnchor() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1000)
        let anchorX = 300.0
        let before = g.time(at: anchorX)
        g.zoom(by: 4, anchorX: anchorX)
        XCTAssertEqual(g.pixelsPerSecond, 40)
        XCTAssertEqual(g.time(at: anchorX), before, accuracy: 1e-9)
        XCTAssertFalse(g.isFitted)
        XCTAssertEqual(g.visibleRange.upperBound - g.visibleRange.lowerBound, 25, accuracy: 1e-9)
    }

    func testZoomIsClampedBetweenFitAndMax() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1000, maxPixelsPerSecond: 200)
        g.zoom(by: 0.1, anchorX: 500)
        XCTAssertEqual(g.pixelsPerSecond, 10)
        XCTAssertEqual(g.startTime, 0)
        g.zoom(by: 1000, anchorX: 500)
        XCTAssertEqual(g.pixelsPerSecond, 200)
        // 锚点附近：time(500) 仍然是 50。
        XCTAssertEqual(g.time(at: 500), 50, accuracy: 1e-9)
    }

    func testZoomNearEdgeStaysInsideVideo() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1000)
        g.zoom(by: 10, anchorX: 0)
        XCTAssertEqual(g.startTime, 0)
        g.zoomToFit()
        g.zoom(by: 10, anchorX: 1000)
        XCTAssertEqual(g.visibleRange.upperBound, 100, accuracy: 1e-9)
    }

    func testScrollIsClamped() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1000)
        g.scroll(byPixels: 500)
        XCTAssertEqual(g.startTime, 0, "铺满时不能滚动")
        g.zoom(by: 2, anchorX: 0)
        g.scroll(byPixels: 400)
        XCTAssertEqual(g.startTime, 20, accuracy: 1e-9)
        g.scroll(byPixels: 100_000)
        XCTAssertEqual(g.startTime, 50, accuracy: 1e-9)
        g.scroll(byPixels: -100_000)
        XCTAssertEqual(g.startTime, 0)
    }

    func testRevealPagesForward() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1000)
        g.zoom(by: 10, anchorX: 0)  // 可见 0…10
        XCTAssertFalse(g.reveal(5))
        XCTAssertTrue(g.reveal(12))
        XCTAssertEqual(g.startTime, 12, accuracy: 1e-9)
        XCTAssertTrue(g.reveal(3))
        XCTAssertEqual(g.startTime, 3, accuracy: 1e-9)
        XCTAssertTrue(g.reveal(99))
        XCTAssertEqual(g.startTime, 90, accuracy: 1e-9)
    }

    func testResizeKeepsFittedOrZoom() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1000)
        g.resize(viewWidth: 500)
        XCTAssertEqual(g.pixelsPerSecond, 5)
        XCTAssertTrue(g.isFitted)

        g.zoom(by: 4, anchorX: 0)  // 20 px/s
        g.resize(viewWidth: 800)
        XCTAssertEqual(g.pixelsPerSecond, 20)
        g.resize(viewWidth: 4000)  // 新的铺满比例是 40，比当前大
        XCTAssertEqual(g.pixelsPerSecond, 40)
        XCTAssertTrue(g.isFitted)
    }

    func testMaxSmallerThanFitDoesNotBreakZoom() {
        var g = TimelineGeometry(duration: 1, viewWidth: 1000, maxPixelsPerSecond: 10)
        g.zoom(by: 5, anchorX: 0)
        XCTAssertEqual(g.pixelsPerSecond, 1000)
    }
}

final class ThumbnailLadderTests: XCTestCase {
    func testLevelFitsThumbnailWidth() {
        // 10 px/s，缩略图 80 px → 至少 8 秒 → 2^3。
        XCTAssertEqual(ThumbnailLadder.level(pixelsPerSecond: 10, thumbnailWidth: 80, minimumInterval: 1.0 / 30), 3)
        // 9 px/s → 8.9 秒 → 2^4。
        XCTAssertEqual(ThumbnailLadder.level(pixelsPerSecond: 9, thumbnailWidth: 80, minimumInterval: 1.0 / 30), 4)
        // 放得很大：不会比一帧更细（1/30 秒 → 2^-4 = 1/16 秒）。
        XCTAssertEqual(ThumbnailLadder.level(pixelsPerSecond: 100_000, thumbnailWidth: 80, minimumInterval: 1.0 / 30), -4)
    }

    func testIntervalIsAtLeastThumbnailWidth() {
        for pps in [0.5, 3, 10, 77, 400, 2400] {
            let level = ThumbnailLadder.level(pixelsPerSecond: pps, thumbnailWidth: 64, minimumInterval: 0.001)
            let width = ThumbnailLadder.interval(level: level) * pps
            XCTAssertGreaterThanOrEqual(width, 64 - 1e-9)
            XCTAssertLessThan(width, 128 + 1e-9)
        }
    }

    func testOnlyVisibleSlots() {
        let slots = ThumbnailLadder.slots(level: 1, visible: 5...11, duration: 100)
        XCTAssertEqual(slots.map(\.key.index), [2, 3, 4, 5])
        XCTAssertEqual(slots.map(\.startTime), [4, 6, 8, 10])
        XCTAssertTrue(slots.allSatisfy { $0.interval == 2 && $0.key.level == 1 })
    }

    func testRequestsMiddleOfSlotNotItsStart() {
        // 第一格不取第 0 秒（很多视频开头是黑的），取格子中间。
        let slots = ThumbnailLadder.slots(level: 3, visible: 0...40, duration: 40)
        XCTAssertEqual(slots.map(\.requestTime), [4, 12, 20, 28, 36])
    }

    func testLastSlotRequestStaysInsideVideo() {
        let slots = ThumbnailLadder.slots(level: 2, visible: 0...10, duration: 10)
        XCTAssertEqual(slots.map(\.key.index), [0, 1, 2])
        XCTAssertEqual(slots.last?.startTime, 8)
        // 最后一格只有 8…10 秒在视频里：取 9 秒。
        XCTAssertEqual(slots.last!.requestTime, 9, accuracy: 1e-9)
        // 很短的视频：不超过末尾前 0.05 秒。
        XCTAssertEqual(ThumbnailLadder.slots(level: 0, visible: 0...0.06, duration: 0.06).first!.requestTime, 0.01, accuracy: 1e-9)
        // 正好在末尾的格子不生成。
        XCTAssertEqual(ThumbnailLadder.slots(level: 1, visible: 0...10, duration: 10).count, 5)
    }

    func testSameKeysAcrossNearbyZoomLevels() {
        // 缩放比例变化但落在同一级别时，键相同，缓存可以复用。
        let a = ThumbnailLadder.level(pixelsPerSecond: 11, thumbnailWidth: 80, minimumInterval: 0.01)
        let b = ThumbnailLadder.level(pixelsPerSecond: 15, thumbnailWidth: 80, minimumInterval: 0.01)
        XCTAssertEqual(a, b)
    }
}

final class LRUCacheTests: XCTestCase {
    func testEvictsLeastRecentlyUsedByCount() {
        var cache = LRUCache<String, Int>(countLimit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)  // a 变成最近使用
        let evicted = cache.insert(3, for: "c")
        XCTAssertEqual(evicted, ["b"])
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.count, 2)
    }

    func testEvictsByCost() {
        var cache = LRUCache<Int, String>(countLimit: 100, costLimit: 10)
        cache.insert("x", for: 1, cost: 4)
        cache.insert("y", for: 2, cost: 4)
        XCTAssertEqual(cache.totalCost, 8)
        cache.insert("z", for: 3, cost: 4)
        XCTAssertFalse(cache.contains(1))
        XCTAssertEqual(cache.totalCost, 8)
        // 单个条目超过上限：不缓存。
        cache.insert("huge", for: 4, cost: 11)
        XCTAssertFalse(cache.contains(4))
        XCTAssertEqual(cache.totalCost, 8)
    }

    func testReplaceUpdatesCost() {
        var cache = LRUCache<Int, String>(countLimit: 10, costLimit: 100)
        cache.insert("a", for: 1, cost: 30)
        cache.insert("b", for: 1, cost: 10)
        XCTAssertEqual(cache.totalCost, 10)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.remove(1), "b")
        XCTAssertEqual(cache.totalCost, 0)
        cache.insert("c", for: 2, cost: 5)
        cache.removeAll()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testPeekDoesNotRefresh() {
        var cache = LRUCache<String, Int>(countLimit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.peek("a")
        cache.insert(3, for: "c")
        XCTAssertFalse(cache.contains("a"))
    }
}

final class TimelineInsetTests: XCTestCase {
    func testInsetLeavesMarginsAtBothEnds() {
        let g = TimelineGeometry(duration: 100, viewWidth: 1020, inset: 10)
        XCTAssertEqual(g.contentWidth, 1000)
        XCTAssertEqual(g.pixelsPerSecond, 10)
        XCTAssertEqual(g.x(for: 0), 10)
        XCTAssertEqual(g.x(for: 100), 1010)
        XCTAssertEqual(g.time(at: 510), 50)
        // 空白里分别是开头和结尾。
        XCTAssertEqual(g.time(at: 3), 0)
        XCTAssertEqual(g.time(at: 1018), 100)
        XCTAssertEqual(g.visibleRange, 0...100)
    }

    func testZoomWithInsetKeepsAnchor() {
        var g = TimelineGeometry(duration: 100, viewWidth: 1020, inset: 10)
        let before = g.time(at: 310)
        g.zoom(by: 4, anchorX: 310)
        XCTAssertEqual(g.time(at: 310), before, accuracy: 1e-9)
        g.scroll(byPixels: 1_000_000)
        XCTAssertEqual(g.x(for: 100), 1010, accuracy: 1e-9, "滚到最右时结尾停在右侧空白之前")
    }
}

final class TimeSelectionTests: XCTestCase {
    func testStartsFull() {
        let s = TimeSelection(duration: 10, minimumLength: 0.04)
        XCTAssertEqual(s.start, 0)
        XCTAssertEqual(s.end, 10)
        XCTAssertTrue(s.isFull)
    }

    func testDraggingIsClamped() {
        var s = TimeSelection(duration: 10, minimumLength: 0.04)
        s.moveStart(to: 3)
        s.moveEnd(to: 7)
        XCTAssertEqual(s.start, 3)
        XCTAssertEqual(s.end, 7)
        XCTAssertEqual(s.length, 4)
        XCTAssertFalse(s.isFull)
        s.moveStart(to: 9)
        XCTAssertEqual(s.start, 6.96, accuracy: 1e-9, "起点不能越过终点")
        s.moveEnd(to: 1)
        XCTAssertEqual(s.end, 7, accuracy: 1e-9, "终点不能越过起点")
        s.moveStart(to: -5)
        s.moveEnd(to: 50)
        XCTAssertTrue(s.isFull)
    }

    func testMarkInAndOut() {
        var s = TimeSelection(duration: 10, minimumLength: 0.04)
        s.markIn(at: 2)
        s.markOut(at: 5)
        XCTAssertEqual(s.start, 2)
        XCTAssertEqual(s.end, 5)
        // 起点设在终点之后：终点回到结尾。
        s.markIn(at: 6)
        XCTAssertEqual(s.start, 6)
        XCTAssertEqual(s.end, 10)
        // 终点设在起点之前：起点回到开头。
        s.markOut(at: 4)
        XCTAssertEqual(s.start, 0)
        XCTAssertEqual(s.end, 4)
        s.reset()
        XCTAssertTrue(s.isFull)
    }

    func testHandleHitTest() {
        XCTAssertEqual(SelectionHandle.hitTest(x: 95, startX: 100, endX: 300), .start)
        XCTAssertEqual(SelectionHandle.hitTest(x: 103, startX: 100, endX: 300), .start)
        XCTAssertNil(SelectionHandle.hitTest(x: 106, startX: 100, endX: 300))
        XCTAssertEqual(SelectionHandle.hitTest(x: 306, startX: 100, endX: 300), .end)
        XCTAssertNil(SelectionHandle.hitTest(x: 200, startX: 100, endX: 300))
        // 两个手柄挨在一起：按中点分。
        XCTAssertEqual(SelectionHandle.hitTest(x: 100, startX: 100, endX: 102), .start)
        XCTAssertEqual(SelectionHandle.hitTest(x: 103, startX: 100, endX: 102), .end)
    }
}
