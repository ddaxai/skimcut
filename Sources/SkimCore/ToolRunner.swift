import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 把字节流切成行；`\n`、`\r`、`\r\n` 都算换行，空行丢弃。
/// 按字节切分，所以多字节 UTF-8 字符不会被切断。
public struct LineSplitter: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let byte = buffer[i]
            if byte == 0x0A || byte == 0x0D {
                if i > start { lines.append(String(decoding: buffer[start..<i], as: UTF8.self)) }
                start = buffer.index(after: i)
            }
            i = buffer.index(after: i)
        }
        buffer = Data(buffer[start...])
        return lines
    }

    public mutating func finish() -> [String] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}

/// 运行外部工具。
///
/// - 参数以数组传给 `Process`，不经过 shell。
/// - 标准输入接 /dev/null（ffmpeg 否则会读终端）。
/// - 任务被取消时结束整棵进程树，删除 `partialOutputs`，并抛出 `CancellationError`。
/// - 非零退出时同样删除 `partialOutputs`，抛出 `ToolError.nonZeroExit`。
public struct ToolRunner: Sendable {
    public var registry: ProcessRegistry
    /// stderr 最多保留的字节数（只保留末尾），防止长日志占用太多内存。
    public var maxStderrBytes: Int

    public init(registry: ProcessRegistry = .shared, maxStderrBytes: Int = 2 * 1024 * 1024) {
        self.registry = registry
        self.maxStderrBytes = maxStderrBytes
    }

    public func run(
        _ command: Command,
        partialOutputs: [URL] = [],
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let job = RunningProcess(
            command: command,
            partialOutputs: partialOutputs,
            registry: registry,
            maxStderrBytes: maxStderrBytes,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// 运行并要求退出码为 0，返回 stdout 文本。
    public func output(_ command: Command) async throws -> String {
        try await run(command).stdoutText
    }
}

/// 收集一个管道的输出。
private final class StreamCollector: @unchecked Sendable {
    private var data = Data()
    private var splitter = LineSplitter()
    private(set) var truncated = false
    private let limit: Int?
    private let onLine: (@Sendable (String) -> Void)?

    init(limit: Int?, onLine: (@Sendable (String) -> Void)?) {
        self.limit = limit
        self.onLine = onLine
    }

    /// 在后台线程里读到 EOF 为止。只在一个线程里调用，所以不需要加锁；
    /// 读完之后才由 DispatchGroup 通知读取结果。
    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if let limit, data.count > limit {
                data = Data(data.suffix(limit / 2))
                truncated = true
            }
            if let onLine { splitter.feed(chunk).forEach(onLine) }
        }
        if let onLine { splitter.finish().forEach(onLine) }
    }

    var collected: Data { data }
}

private final class RunningProcess: @unchecked Sendable {
    let command: Command
    let partialOutputs: [URL]
    let registry: ProcessRegistry
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutCollector: StreamCollector
    let stderrCollector: StreamCollector

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    init(
        command: Command,
        partialOutputs: [URL],
        registry: ProcessRegistry,
        maxStderrBytes: Int,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) {
        self.command = command
        self.partialOutputs = partialOutputs
        self.registry = registry
        self.stdoutCollector = StreamCollector(limit: nil, onLine: onStdoutLine)
        self.stderrCollector = StreamCollector(limit: maxStderrBytes, onLine: onStderrLine)
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        process.executableURL = command.executable
        process.arguments = command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
        }
        if let dir = command.workingDirectory { process.currentDirectoryURL = dir }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            continuation.resume(throwing: ToolError.launchFailed(command: command, reason: error.localizedDescription))
            return
        }
        pid = process.processIdentifier
        registry.register(pid, partialOutputs: partialOutputs)
        lock.unlock()

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .utility).async { [stdoutCollector] in
            stdoutCollector.drain(outHandle)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [stderrCollector] in
            stderrCollector.drain(errHandle)
            group.leave()
        }

        group.notify(queue: .global(qos: .utility)) { [self] in
            registry.unregister(pid)
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()

            let result = ProcessResult(
                command: command,
                exitCode: process.terminationStatus,
                stdout: stdoutCollector.collected,
                stderr: stderrCollector.collected,
                stderrTruncated: stderrCollector.truncated
            )
            if wasCancelled {
                removePartialOutputs()
                continuation.resume(throwing: CancellationError())
            } else if result.exitCode != 0 || process.terminationReason != .exit {
                removePartialOutputs()
                continuation.resume(throwing: ToolError.nonZeroExit(result))
            } else {
                continuation.resume(returning: result)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        lock.unlock()
        guard target > 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessKiller.terminateTree(target)
        }
    }

    private func removePartialOutputs() {
        for url in partialOutputs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
