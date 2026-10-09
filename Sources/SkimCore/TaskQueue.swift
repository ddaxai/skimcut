import Foundation

public struct JobID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

public enum JobStatus: Sendable, Equatable {
    case queued
    case running
    case succeeded
    /// `message` 是给用户看的中文说明，`log` 是完整命令和日志（可能没有）。
    case failed(message: String, log: String?)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }
}

public struct JobSnapshot: Sendable, Identifiable, Equatable {
    public let id: JobID
    public let title: String
    public var status: JobStatus
    /// 0…1；未知时为 nil。
    public var progress: Double?
}

/// 交给任务的上下文，用来报告进度。
public struct JobContext: Sendable {
    public let id: JobID
    let progressSink: @Sendable (Double?) -> Void

    public func report(progress: Double?) { progressSink(progress) }
}

public typealias JobWork = @Sendable (JobContext) async throws -> Void

/// 所有耗时任务（剪切、导出、分析、生成预览）都进这个队列。
///
/// - 默认一次只运行一个任务，保持轻量；
/// - 取消运行中的任务会取消它的 Swift Task，ToolRunner 随之结束子进程并删除半成品；
/// - 没有计时器和轮询：只有任务状态变化时才通知观察者。
public actor TaskQueue {
    private struct Entry {
        var snapshot: JobSnapshot
        var work: JobWork?
        var task: Task<Void, Never>?
    }

    public let maxConcurrent: Int
    private var entries: [JobID: Entry] = [:]
    private var order: [JobID] = []
    private var observers: [UUID: AsyncStream<[JobSnapshot]>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 当前所有任务（按加入顺序）。
    public var jobs: [JobSnapshot] { order.compactMap { entries[$0]?.snapshot } }

    public var isIdle: Bool {
        !entries.values.contains { !$0.snapshot.status.isFinished }
    }

    @discardableResult
    public func enqueue(title: String, work: @escaping JobWork) -> JobID {
        let id = JobID()
        entries[id] = Entry(snapshot: JobSnapshot(id: id, title: title, status: .queued, progress: nil), work: work)
        order.append(id)
        pump()
        publish()
        return id
    }

    public func cancel(_ id: JobID) {
        guard var entry = entries[id] else { return }
        switch entry.snapshot.status {
        case .queued:
            entry.snapshot.status = .cancelled
            entry.work = nil
            entries[id] = entry
            publish()
            resumeIdleWaitersIfNeeded()
        case .running:
            entry.task?.cancel()
        default:
            break
        }
    }

    public func cancelAll() {
        for id in order { cancel(id) }
    }

    /// 从列表里去掉已经结束的任务。
    public func removeFinished() {
        order.removeAll { entries[$0]?.snapshot.status.isFinished ?? true }
        entries = entries.filter { !$0.value.snapshot.status.isFinished }
        publish()
    }

    /// 订阅任务列表的变化；订阅时先收到一次当前列表。
    public func updates() -> AsyncStream<[JobSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [JobSnapshot].self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        observers[key] = continuation
        continuation.yield(jobs)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        return stream
    }

    /// 等到没有排队或运行中的任务。
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - 内部

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
    }

    private var runningCount: Int {
        entries.values.filter { $0.snapshot.status == .running }.count
    }

    private func pump() {
        while runningCount < maxConcurrent,
              let next = order.first(where: { entries[$0]?.snapshot.status == .queued }),
              var entry = entries[next],
              let work = entry.work {
            entry.snapshot.status = .running
            entry.work = nil
            let context = JobContext(id: next) { [weak self] progress in
                Task { await self?.setProgress(next, progress) }
            }
            entry.task = Task { [weak self] in
                let outcome: JobStatus
                do {
                    try await work(context)
                    outcome = Task.isCancelled ? .cancelled : .succeeded
                } catch is CancellationError {
                    outcome = .cancelled
                } catch let error as ToolError {
                    outcome = .failed(message: error.errorDescription ?? "\(error)", log: error.fullLog)
                } catch {
                    outcome = .failed(message: error.localizedDescription, log: nil)
                }
                await self?.finish(next, outcome)
            }
            entries[next] = entry
        }
    }

    private func setProgress(_ id: JobID, _ progress: Double?) {
        guard var entry = entries[id], entry.snapshot.status == .running else { return }
        entry.snapshot.progress = progress
        entries[id] = entry
        publish()
    }

    private func finish(_ id: JobID, _ status: JobStatus) {
        if var entry = entries[id] {
            entry.snapshot.status = status
            if status == .succeeded { entry.snapshot.progress = 1 }
            entry.task = nil
            entries[id] = entry
        }
        pump()
        publish()
        resumeIdleWaitersIfNeeded()
    }

    private func publish() {
        guard !observers.isEmpty else { return }
        let current = jobs
        for continuation in observers.values { continuation.yield(current) }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
