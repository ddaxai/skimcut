import Foundation
import XCTest
@testable import SkimCore
#if canImport(Glibc)
import Glibc
#endif

final class ToolRunnerTests: XCTestCase {
    let runner = ToolRunner(registry: ProcessRegistry())

    func testArgumentsArePassedVerbatim() async throws {
        let tricky = ["my video.mp4", "it's \"quoted\"", "中文 文件名.mkv", "$HOME", "a;b|c&d", ""]
        let result = try await runner.run(TestSupport.sh(#"for a in "$@"; do printf '[%s]\n' "$a"; done"#, tricky))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutText, tricky.map { "[\($0)]\n" }.joined())
    }

    func testEnvironmentIsAddedToProcess() async throws {
        var cmd = TestSupport.sh(#"printf '%s|%s' "$FFMPEG_PATH" "${PATH:+has-path}""#)
        cmd.environment["FFMPEG_PATH"] = "/opt/homebrew/bin/ffmpeg"
        let out = try await runner.output(cmd)
        XCTAssertEqual(out, "/opt/homebrew/bin/ffmpeg|has-path")
    }

    func testStdinIsNotInherited() async throws {
        // 标准输入接 /dev/null：cat 立即读到 EOF 并退出。
        let out = try await runner.output(TestSupport.sh("cat; echo done"))
        XCTAssertEqual(out, "done\n")
    }

    func testNonZeroExitThrowsWithLogAndDeletesPartialOutput() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("out.mp4")
        let cmd = TestSupport.sh(#"echo started > "$1"; echo "boom: bad input" >&2; exit 3"#, [partial.path])
        do {
            _ = try await runner.run(cmd, partialOutputs: [partial])
            XCTFail("应该抛出错误")
        } catch let error as ToolError {
            guard case .nonZeroExit(let result) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(result.exitCode, 3)
            XCTAssertEqual(error.errorDescription, "sh 运行失败（退出码 3）：boom: bad input")
            XCTAssertTrue(error.fullLog?.contains("$ /bin/sh -c") == true)
            XCTAssertTrue(error.fullLog?.contains("boom: bad input") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testLaunchFailure() async throws {
        let cmd = Command(executable: URL(fileURLWithPath: "/nonexistent/tool"))
        do {
            _ = try await runner.run(cmd)
            XCTFail("应该抛出错误")
        } catch ToolError.launchFailed {
        }
    }

    func testStreamsLinesWhileRunning() async throws {
        let lines = LockedBox<[String]>([])
        _ = try await runner.run(TestSupport.sh(#"printf 'a=1\nb=2\rc=3'; printf 'warn\n' >&2"#),
                                 onStdoutLine: { line in lines.mutate { $0.append(line) } },
                                 onStderrLine: { line in lines.mutate { $0.append("E:" + line) } })
        XCTAssertEqual(lines.value.filter { !$0.hasPrefix("E:") }, ["a=1", "b=2", "c=3"])
        XCTAssertEqual(lines.value.filter { $0.hasPrefix("E:") }, ["E:warn"])
    }

    func testStderrIsTruncatedToLimit() async throws {
        let small = ToolRunner(registry: ProcessRegistry(), maxStderrBytes: 1000)
        let result = try await small.run(TestSupport.sh("i=0; while [ $i -lt 500 ]; do echo line$i >&2; i=$((i+1)); done"))
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertLessThanOrEqual(result.stderr.count, 1000)
        XCTAssertTrue(result.stderrText.hasSuffix("line499\n"))
    }

    func testCancellationKillsProcessTreeAndDeletesPartialOutput() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let partial = dir.appendingPathComponent("partial.mp4")
        let registry = ProcessRegistry()
        let runner = ToolRunner(registry: registry)
        let childPID = LockedBox<pid_t>(0)
        // sh 启动一个后台子进程（类似 ffmpeg-normalize 启动 ffmpeg），然后等待。
        let cmd = TestSupport.sh(#"echo x > "$1"; sleep 30 & echo "$!"; wait"#, [partial.path])

        let task = Task {
            try await runner.run(cmd, partialOutputs: [partial], onStdoutLine: { line in
                if let pid = pid_t(line) { childPID.set(pid) }
            })
        }
        try await waitFor { childPID.value > 0 && FileManager.default.fileExists(atPath: partial.path) }
        XCTAssertEqual(registry.activePIDs.count, 1)
        let parent = registry.activePIDs[0]

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应该被取消")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(registry.activePIDs.isEmpty)
        try await waitFor { !ProcessKiller.isAlive(parent) && !ProcessKiller.isAlive(childPID.value) }
    }

    func testCancelledBeforeStartDoesNotLaunch() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        let runner = self.runner
        let task = Task {
            try await Task.sleep(nanoseconds: 200_000_000)
            return try await runner.run(TestSupport.sh(#"touch "$1""#, [marker.path]))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应该被取消")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRegistryTerminateAllKillsEverythingAndCleansUp() async throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = ProcessRegistry()
        let runner = ToolRunner(registry: registry)
        let partial = dir.appendingPathComponent("p.mkv")
        let task = Task { try await runner.run(TestSupport.sh(#"echo x > "$1"; sleep 30"#, [partial.path]), partialOutputs: [partial]) }
        try await waitFor { registry.activePIDs.count == 1 && FileManager.default.fileExists(atPath: partial.path) }
        registry.terminateAll(grace: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(registry.activePIDs.isEmpty)
        // 进程被信号结束，不是正常退出，所以算失败。
        do {
            _ = try await task.value
            XCTFail("应该失败")
        } catch ToolError.nonZeroExit {
        }
    }
}

/// 线程安全的小盒子，测试里用来从回调收集数据。
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// 等待条件成立（最多 `timeout` 秒）。
func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool,
             file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("等待超时", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
