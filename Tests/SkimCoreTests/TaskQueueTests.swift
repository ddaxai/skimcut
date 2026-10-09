import Foundation
import XCTest
@testable import SkimCore

final class TaskQueueTests: XCTestCase {
    func testRunsJobsOneAtATimeInOrder() async throws {
        let queue = TaskQueue()
        let log = LockedBox<[String]>([])
        for name in ["a", "b", "c"] {
            await queue.enqueue(title: name) { _ in
                log.mutate { $0.append("start \(name)") }
                try await Task.sleep(nanoseconds: 30_000_000)
                log.mutate { $0.append("end \(name)") }
            }
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(log.value, ["start a", "end a", "start b", "end b", "start c", "end c"])
        let statuses = await queue.jobs.map(\.status)
        XCTAssertEqual(statuses, [.succeeded, .succeeded, .succeeded])
    }

    func testCancelQueuedJobNeverRuns() async throws {
        let queue = TaskQueue()
        let ran = LockedBox(false)
        let gate = LockedBox(false)
        await queue.enqueue(title: "blocker") { _ in
            while !gate.value { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let second = await queue.enqueue(title: "second") { _ in ran.set(true) }
        await queue.cancel(second)
        gate.set(true)
        await queue.waitUntilIdle()
        XCTAssertFalse(ran.value)
        let statuses = await queue.jobs.map(\.status)
        XCTAssertEqual(statuses, [.succeeded, .cancelled])
    }

    func testCancelRunningJob() async throws {
        let queue = TaskQueue()
        let started = LockedBox(false)
        let id = await queue.enqueue(title: "long") { _ in
            started.set(true)
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        try await waitFor { started.value }
        await queue.cancel(id)
        await queue.waitUntilIdle()
        let statuses = await queue.jobs.map(\.status)
        XCTAssertEqual(statuses, [.cancelled])
    }

    func testCancelRunningProcessJob() async throws {
        let queue = TaskQueue()
        let registry = ProcessRegistry()
        let runner = ToolRunner(registry: registry)
        let id = await queue.enqueue(title: "sleep") { _ in
            _ = try await runner.run(TestSupport.sh("sleep 30"))
        }
        try await waitFor { registry.activePIDs.count == 1 }
        await queue.cancel(id)
        await queue.waitUntilIdle()
        XCTAssertTrue(registry.activePIDs.isEmpty)
        let statuses = await queue.jobs.map(\.status)
        XCTAssertEqual(statuses, [.cancelled])
    }

    func testFailureCarriesChineseMessageAndLog() async throws {
        let queue = TaskQueue()
        let runner = ToolRunner(registry: ProcessRegistry())
        await queue.enqueue(title: "fail") { _ in
            _ = try await runner.run(TestSupport.sh("echo 'Invalid data found' >&2; exit 1"))
        }
        await queue.waitUntilIdle()
        let status = await queue.jobs.first?.status
        guard case .failed(let message, let log) = status else { return XCTFail("\(String(describing: status))") }
        XCTAssertEqual(message, "sh 运行失败（退出码 1）：Invalid data found")
        XCTAssertTrue(log?.contains("Invalid data found") == true)
    }

    func testCancelAllAndProgressUpdates() async throws {
        let queue = TaskQueue()
        let updates = await queue.updates()
        let seenProgress = LockedBox<[Double]>([])
        let observer = Task {
            for await jobs in updates {
                if let p = jobs.first?.progress { seenProgress.mutate { $0.append(p) } }
            }
        }
        let started = LockedBox(false)
        await queue.enqueue(title: "progress") { ctx in
            ctx.report(progress: 0.5)
            started.set(true)
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        await queue.enqueue(title: "queued") { _ in }
        try await waitFor { started.value && seenProgress.value.contains(0.5) }
        await queue.cancelAll()
        await queue.waitUntilIdle()
        let statuses = await queue.jobs.map(\.status)
        XCTAssertEqual(statuses, [.cancelled, .cancelled])
        await queue.removeFinished()
        let remaining = await queue.jobs
        XCTAssertTrue(remaining.isEmpty)
        observer.cancel()
    }

    func testWaitUntilIdleReturnsImmediatelyWhenEmpty() async {
        let queue = TaskQueue()
        await queue.waitUntilIdle()
        let idle = await queue.isIdle
        XCTAssertTrue(idle)
    }
}
