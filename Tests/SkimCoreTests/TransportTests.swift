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

final class PlaybackKeyMapTests: XCTestCase {
    private func cmd(_ code: UInt16, _ chars: String?, _ mods: KeyModifiers = []) -> PlaybackCommand? {
        PlaybackKeyMap.command(keyCode: code, characters: chars, modifiers: mods)
    }

    func testPlainKeys() {
        XCTAssertEqual(cmd(49, " "), .togglePlay)
        XCTAssertEqual(cmd(38, "j"), .shuttleReverse)
        XCTAssertEqual(cmd(40, "k"), .shuttleStop)
        XCTAssertEqual(cmd(37, "l"), .shuttleForward)
        XCTAssertEqual(cmd(123, nil), .stepBackward)
        XCTAssertEqual(cmd(124, nil), .stepForward)
        XCTAssertEqual(cmd(0, "a"), nil)
        XCTAssertEqual(cmd(34, "i"), .markIn)
        XCTAssertEqual(cmd(31, "o"), .markOut)
        XCTAssertNil(cmd(34, "i", .command))
    }

    func testCapsLockLettersStillWork() {
        XCTAssertEqual(cmd(37, "L"), .shuttleForward)
    }

    func testShiftArrowsJump() {
        XCTAssertEqual(cmd(123, nil, .shift), .jumpBackward)
        XCTAssertEqual(cmd(124, nil, .shift), .jumpForward)
        XCTAssertNil(cmd(37, "l", .shift))
        XCTAssertNil(cmd(49, " ", .shift))
    }

    func testCommandZoom() {
        XCTAssertEqual(cmd(24, "=", .command), .zoomIn)
        XCTAssertEqual(cmd(24, "+", [.command, .shift]), .zoomIn)
        XCTAssertEqual(cmd(27, "-", .command), .zoomOut)
        XCTAssertNil(cmd(37, "l", .command), "⌘L 之类留给菜单")
        XCTAssertNil(cmd(123, nil, .command))
    }

    func testOtherModifiersAreIgnored() {
        XCTAssertNil(cmd(49, " ", .control))
        XCTAssertNil(cmd(124, nil, .option))
        XCTAssertNil(cmd(24, "=", [.command, .option]))
    }
}

final class TimelineTicksTests: XCTestCase {
    func testInterval() {
        XCTAssertEqual(TimelineTicks.interval(pixelsPerSecond: 10, minimumPixels: 80), 10)
        XCTAssertEqual(TimelineTicks.interval(pixelsPerSecond: 1000, minimumPixels: 80), 0.1)
        XCTAssertEqual(TimelineTicks.interval(pixelsPerSecond: 0.1, minimumPixels: 80), 900)
        XCTAssertEqual(TimelineTicks.interval(pixelsPerSecond: 0.001, minimumPixels: 80), 82800)
    }

    func testLabel() {
        XCTAssertEqual(TimelineTicks.label(0, interval: 10), "0:00")
        XCTAssertEqual(TimelineTicks.label(75, interval: 5), "1:15")
        XCTAssertEqual(TimelineTicks.label(3725, interval: 60), "1:02:05")
        XCTAssertEqual(TimelineTicks.label(1.5, interval: 0.5), "0:01.5")
    }
}
