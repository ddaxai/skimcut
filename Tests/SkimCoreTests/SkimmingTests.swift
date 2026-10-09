import XCTest
@testable import SkimCore

final class ChaseSeekerTests: XCTestCase {
    func testOnlyOneSeekInFlightAndLatestTargetWins() {
        var chase = ChaseSeeker()
        XCTAssertEqual(chase.request(SeekRequest(time: 1)), SeekRequest(time: 1))
        XCTAssertTrue(chase.isSeeking)
        // seek 进行中：不发新的，只记住最新的目标。
        XCTAssertNil(chase.request(SeekRequest(time: 2)))
        XCTAssertNil(chase.request(SeekRequest(time: 3, tolerance: 0.5)))
        XCTAssertEqual(chase.pending, SeekRequest(time: 3, tolerance: 0.5))
        // 完成后只发最新的那个，中间的 2 被跳过。
        XCTAssertEqual(chase.complete(finished: true), SeekRequest(time: 3, tolerance: 0.5))
        XCTAssertNil(chase.complete(finished: true))
        XCTAssertFalse(chase.isSeeking)
    }

    func testDuplicateOfCompletedSeekIsSkipped() {
        var chase = ChaseSeeker()
        _ = chase.request(SeekRequest(time: 5))
        _ = chase.complete(finished: true)
        XCTAssertNil(chase.request(SeekRequest(time: 5)))
        XCTAssertNil(chase.request(SeekRequest(time: 5, tolerance: 1)), "精确位置已经满足更宽的容差")
    }

    func testExactSeekAfterTolerantSeekToSameTime() {
        var chase = ChaseSeeker()
        _ = chase.request(SeekRequest(time: 5, tolerance: 0.5))
        _ = chase.complete(finished: true)
        XCTAssertEqual(chase.request(SeekRequest(time: 5)), SeekRequest(time: 5), "停下后要补一次精确 seek")
    }

    func testInterruptedSeekIsNotRemembered() {
        var chase = ChaseSeeker()
        _ = chase.request(SeekRequest(time: 5))
        _ = chase.complete(finished: false)
        XCTAssertEqual(chase.request(SeekRequest(time: 5)), SeekRequest(time: 5))
    }

    func testInvalidateAfterPlayback() {
        var chase = ChaseSeeker()
        _ = chase.request(SeekRequest(time: 5))
        _ = chase.complete(finished: true)
        chase.invalidate()
        XCTAssertEqual(chase.request(SeekRequest(time: 5)), SeekRequest(time: 5))
    }

    func testDropPending() {
        var chase = ChaseSeeker()
        _ = chase.request(SeekRequest(time: 1))
        _ = chase.request(SeekRequest(time: 2))
        chase.dropPending()
        XCTAssertNil(chase.complete(finished: true))
    }

    func testPendingSameAsCompletedIsSkipped() {
        var chase = ChaseSeeker()
        _ = chase.request(SeekRequest(time: 1))
        _ = chase.request(SeekRequest(time: 1))
        XCTAssertNil(chase.complete(finished: true))
    }
}

final class SkimTolerancePolicyTests: XCTestCase {
    func testSlowMovementIsExact() {
        let policy = SkimTolerancePolicy()
        XCTAssertEqual(policy.tolerance(speed: 0, secondsPerPixel: 0.1), 0)
        XCTAssertEqual(policy.tolerance(speed: 299, secondsPerPixel: 0.1), 0)
    }

    func testFastMovementScalesWithZoomAndIsClamped() {
        let policy = SkimTolerancePolicy()
        // 1000 px/s × 0.01 s/px × 0.1 s = 1 秒
        XCTAssertEqual(policy.tolerance(speed: 1000, secondsPerPixel: 0.01), 1, accuracy: 1e-9)
        // 放得很大时不小于 0.1 秒
        XCTAssertEqual(policy.tolerance(speed: 1000, secondsPerPixel: 0.0001), 0.1, accuracy: 1e-9)
        // 整段很长时不超过 2 秒
        XCTAssertEqual(policy.tolerance(speed: 5000, secondsPerPixel: 1), 2, accuracy: 1e-9)
    }

    func testVelocityTracker() {
        var v = PointerVelocityTracker()
        XCTAssertEqual(v.add(x: 0, timestamp: 0), 0)
        XCTAssertEqual(v.add(x: 10, timestamp: 0.01), 500, accuracy: 1e-6)  // 平滑：0.5×0 + 0.5×1000
        XCTAssertEqual(v.add(x: 20, timestamp: 0.02), 750, accuracy: 1e-6)
        // 停了很久再动：重新计算，不受之前影响。
        XCTAssertEqual(v.add(x: 21, timestamp: 1.0), 1 / 0.98, accuracy: 1e-6)
    }
}

final class SkimControllerTests: XCTestCase {
    private func move(_ c: inout SkimController, x: Double, t: Double, at ts: Double, playing: Bool = false) -> [SkimController.Action] {
        c.pointerMoved(x: x, time: t, timestamp: ts, secondsPerPixel: 0.01, userIsPlaying: playing)
    }

    private func generation(_ actions: [SkimController.Action]) -> Int? {
        for a in actions {
            if case .scheduleTimers(let g, _, _) = a { return g }
        }
        return nil
    }

    func testHoverSeeksAndSchedulesTimers() {
        var c = SkimController()
        let actions = move(&c, x: 100, t: 1, at: 0)
        XCTAssertEqual(actions.first, .seek(SeekRequest(time: 1)))
        XCTAssertEqual(actions.last, .scheduleTimers(generation: 1, settle: 0.1, dwell: 0.3))
        XCTAssertEqual(c.state, .skimming)
        XCTAssertEqual(c.skimmerTime, 1)
    }

    func testFastMoveUsesToleranceThenSettlesExactly() {
        var c = SkimController()
        _ = move(&c, x: 0, t: 0, at: 0)
        let actions = move(&c, x: 50, t: 0.5, at: 0.02)  // 2500 px/s 平滑后 1250 px/s
        guard case .seek(let req) = actions.first else { return XCTFail("应该 seek") }
        XCTAssertGreaterThan(req.tolerance, 0)
        let g = generation(actions)!
        XCTAssertEqual(c.timerFired(.settle, generation: g), [.seek(SeekRequest(time: 0.5))])
        // 再到点不会重复。
        XCTAssertEqual(c.timerFired(.settle, generation: g), [])
    }

    func testSettleNotNeededWhenAlreadyExact() {
        var c = SkimController()
        let g = generation(move(&c, x: 0, t: 2, at: 0))!
        XCTAssertEqual(c.timerFired(.settle, generation: g), [])
    }

    func testDwellStartsPlaybackAndMovingStopsIt() {
        var c = SkimController()
        let g = generation(move(&c, x: 0, t: 2, at: 0))!
        XCTAssertEqual(c.timerFired(.dwell, generation: g), [.startDwellPlayback(at: 2)])
        XCTAssertEqual(c.state, .dwellPlaying)
        c.dwellPlaybackAdvanced(to: 2.5)
        XCTAssertEqual(c.skimmerTime, 2.5)

        let actions = move(&c, x: 10, t: 2.1, at: 1)
        XCTAssertEqual(actions.first, .stopDwellPlayback)
        XCTAssertEqual(actions[1], .seek(SeekRequest(time: 2.1)))
        XCTAssertEqual(c.state, .skimming)
    }

    func testStaleTimersAreIgnored() {
        var c = SkimController()
        let g1 = generation(move(&c, x: 0, t: 1, at: 0))!
        let g2 = generation(move(&c, x: 1, t: 1.01, at: 0.5))!
        XCTAssertNotEqual(g1, g2)
        XCTAssertEqual(c.timerFired(.dwell, generation: g1), [])
        XCTAssertEqual(c.state, .skimming)
        XCTAssertEqual(c.timerFired(.dwell, generation: g2), [.startDwellPlayback(at: 1.01)])
    }

    func testExitReturnsToPlayhead() {
        var c = SkimController()
        let g = generation(move(&c, x: 0, t: 1, at: 0))!
        XCTAssertEqual(c.pointerExited(), [.cancelTimers, .returnToPlayhead])
        XCTAssertEqual(c.state, .outside)
        XCTAssertNil(c.skimmerTime)
        XCTAssertEqual(c.timerFired(.dwell, generation: g), [], "离开后旧定时器失效")
        XCTAssertEqual(c.pointerExited(), [])
    }

    func testExitDuringDwellPlaybackStopsIt() {
        var c = SkimController()
        let g = generation(move(&c, x: 0, t: 1, at: 0))!
        _ = c.timerFired(.dwell, generation: g)
        XCTAssertEqual(c.pointerExited(), [.cancelTimers, .stopDwellPlayback, .returnToPlayhead])
    }

    func testClickMovesPlayheadAndStopsDwellPlayback() {
        var c = SkimController()
        let g = generation(move(&c, x: 0, t: 1, at: 0))!
        _ = c.timerFired(.dwell, generation: g)
        XCTAssertEqual(c.clicked(at: 1.4), [.stopDwellPlayback, .cancelTimers, .movePlayhead(to: 1.4)])
        XCTAssertEqual(c.state, .skimming)
        XCTAssertEqual(c.timerFired(.dwell, generation: g), [])
    }

    func testUserPlaybackIsNotInterruptedByHover() {
        var c = SkimController()
        XCTAssertEqual(move(&c, x: 0, t: 1, at: 0, playing: true), [])
        XCTAssertEqual(c.state, .passive)
        XCTAssertEqual(c.skimmerTime, 1, "仍然显示 skimmer 线")
        // 用户暂停后再移动：恢复 skimming。
        XCTAssertEqual(move(&c, x: 5, t: 1.05, at: 1).first, .seek(SeekRequest(time: 1.05)))
        XCTAssertEqual(c.state, .skimming)
        // 开始正常播放：停掉定时器。
        XCTAssertEqual(c.userPlaybackStarted(), [.cancelTimers])
        XCTAssertEqual(c.state, .passive)
        XCTAssertEqual(c.pointerExited(), [.cancelTimers])
    }

    func testDisabledSkimmingDoesNothing() {
        var c = SkimController(configuration: .init(enabled: false))
        XCTAssertEqual(move(&c, x: 0, t: 1, at: 0), [])
        XCTAssertNil(c.skimmerTime)
        XCTAssertEqual(c.clicked(at: 3), [.cancelTimers, .movePlayhead(to: 3)])
    }

    func testDisablingWhileSkimmingReturnsToPlayhead() {
        var c = SkimController()
        _ = move(&c, x: 0, t: 1, at: 0)
        XCTAssertEqual(c.updateConfiguration(.init(enabled: false)), [.cancelTimers, .returnToPlayhead])
        XCTAssertEqual(c.state, .passive)
        XCTAssertNil(c.skimmerTime)
    }

    func testCustomDwellIsPassedToTimers() {
        var c = SkimController(configuration: .init(dwell: 0.8))
        XCTAssertEqual(move(&c, x: 0, t: 1, at: 0).last, .scheduleTimers(generation: 1, settle: 0.1, dwell: 0.8))
    }

    func testDwellPlaybackEndedReturnsToSkimming() {
        var c = SkimController()
        let g = generation(move(&c, x: 0, t: 1, at: 0))!
        _ = c.timerFired(.dwell, generation: g)
        c.dwellPlaybackEnded()
        XCTAssertEqual(c.state, .skimming)
    }
}
