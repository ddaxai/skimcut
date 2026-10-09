import XCTest
@testable import SkimCore

final class ShuttleTests: XCTestCase {
    func testLAccelerates() {
        var s = Shuttle()
        XCTAssertEqual(s.pressL(), 1)
        XCTAssertEqual(s.pressL(), 2)
        XCTAssertEqual(s.pressL(), 4)
        XCTAssertEqual(s.pressL(), 8)
        XCTAssertEqual(s.pressL(), 8)
    }

    func testJReversesAndAccelerates() {
        var s = Shuttle()
        XCTAssertEqual(s.pressJ(), -1)
        XCTAssertEqual(s.pressJ(), -2)
        XCTAssertEqual(s.pressL(), 1, "反向时按 L 变成正向 1×")
        XCTAssertEqual(s.pressJ(), -1)
        XCTAssertEqual(s.pressK(), 0)
    }

    func testSpaceToggles() {
        var s = Shuttle()
        XCTAssertEqual(s.togglePlay(), 1)
        XCTAssertEqual(s.togglePlay(), 0)
        _ = s.pressL()
        _ = s.pressL()
        XCTAssertEqual(s.togglePlay(), 0, "快进时按空格暂停")
    }

    func testCapabilities() {
        var s = Shuttle(capabilities: .init(reverse: false, fastForward: false, fastReverse: false))
        XCTAssertEqual(s.pressJ(), 0, "不能倒放：不动")
        XCTAssertEqual(s.pressL(), 1)
        XCTAssertEqual(s.pressL(), 1, "不能快进：停在 1×")

        var r = Shuttle(capabilities: .init(reverse: true, fastForward: true, fastReverse: false))
        XCTAssertEqual(r.pressJ(), -1)
        XCTAssertEqual(r.pressJ(), -1, "不能快速倒放：停在 -1×")
    }

    func testSync() {
        var s = Shuttle()
        _ = s.pressL()
        s.sync(rate: 0)  // 播放到结尾自己停了
        XCTAssertEqual(s.togglePlay(), 1)
    }

    func testJump() {
        XCTAssertEqual(Shuttle.jump(from: 5, by: 1, duration: 10), 6)
        XCTAssertEqual(Shuttle.jump(from: 0.5, by: -1, duration: 10), 0)
        XCTAssertEqual(Shuttle.jump(from: 9.5, by: 1, duration: 10), 10)
    }
}

final class FrameGridTests: XCTestCase {
    func testIntegerFrameRate() {
        let grid = FrameGrid(framesPerSecond: 25)
        XCTAssertEqual(grid.secondsPerFrame, 0.04, accuracy: 1e-12)
        XCTAssertEqual(grid.frameIndex(at: 0), 0)
        XCTAssertEqual(grid.frameIndex(at: 0.04), 1)
        XCTAssertEqual(grid.frameIndex(at: 0.0399999), 1, "浮点误差不能落到上一帧")
        XCTAssertEqual(grid.frameIndex(at: 0.059), 1)
        XCTAssertEqual(grid.step(from: 1.0, by: 1, duration: 10).seconds, 1.04, accuracy: 1e-12)
        XCTAssertEqual(grid.step(from: 1.0, by: -1, duration: 10).seconds, 0.96, accuracy: 1e-12)
    }

    func testNTSCUsesExactRational() {
        let grid = FrameGrid(framesPerSecond: 30000.0 / 1001.0)
        XCTAssertEqual(grid.frameDuration, RationalTime(value: 1001, timescale: 30000))
        let t = grid.time(ofFrame: 300)
        XCTAssertEqual(t, RationalTime(value: 300_300, timescale: 30000))
        XCTAssertEqual(grid.frameIndex(at: t.seconds), 300)
        XCTAssertEqual(FrameGrid(framesPerSecond: 23.976).frameDuration, RationalTime(value: 1001, timescale: 24000))
        XCTAssertEqual(FrameGrid(framesPerSecond: 59.94).frameDuration, RationalTime(value: 1001, timescale: 60000))
    }

    func testStepIsClampedToVideo() {
        let grid = FrameGrid(framesPerSecond: 30)
        XCTAssertEqual(grid.step(from: 0, by: -1, duration: 2).value, 0)
        // 2 秒 30 fps：最后一帧是第 59 帧。
        XCTAssertEqual(grid.lastFrameIndex(duration: 2), 59)
        XCTAssertEqual(grid.frameIndex(at: grid.step(from: 1.98, by: 5, duration: 2).seconds), 59)
    }

    func testInvalidFrameRateFallsBackTo30() {
        XCTAssertEqual(FrameGrid(framesPerSecond: 0).secondsPerFrame, 1.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(FrameGrid(framesPerSecond: .nan).secondsPerFrame, 1.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(FrameGrid(frameDuration: RationalTime(value: 0, timescale: 600)).secondsPerFrame, 1.0 / 30, accuracy: 1e-12)
    }
}
