import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 结束一个进程以及它的所有子孙进程（例如 ffmpeg-normalize 启动的 ffmpeg）。
public enum ProcessKiller {
    /// 先发 SIGTERM，最多等 `grace` 秒，仍然存活的再发 SIGKILL。会阻塞调用线程。
    public static func terminateTree(_ pid: pid_t, grace: TimeInterval = 2.0) {
        terminateTrees([pid], grace: grace)
    }

    public static func terminateTrees(_ roots: [pid_t], grace: TimeInterval = 2.0) {
        // 先收集整棵树：父进程一死，子进程会被过继，之后就找不到了。
        var all: [pid_t] = []
        for root in roots where root > 0 {
            all.append(root)
            all.append(contentsOf: descendants(of: root))
        }
        guard !all.isEmpty else { return }
        for pid in all { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !all.contains(where: isAlive) { return }
            usleep(20_000)
        }
        for pid in all where isAlive(pid) { kill(pid, SIGKILL) }
    }

    /// 进程是否还在运行（僵尸进程算已结束）。
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        #if os(Linux)
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")") {
            let rest = stat[stat.index(after: close)...].split(separator: " ")
            if rest.first == "Z" || rest.first == "X" { return false }
        }
        #endif
        return true
    }

    /// 所有子孙进程的 pid。
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var frontier = [pid]
        while let current = frontier.popLast() {
            let kids = children(of: current).filter { !result.contains($0) && $0 != pid }
            result.append(contentsOf: kids)
            frontier.append(contentsOf: kids)
        }
        return result
    }

    static func children(of pid: pid_t) -> [pid_t] {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        var kids: [pid_t] = []
        for entry in entries {
            guard let child = pid_t(entry),
                  let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                  let close = stat.lastIndex(of: ")")
            else { continue }
            // 格式：pid (comm) state ppid …；comm 里可能有空格和括号，所以从最后一个 ')' 之后开始解析。
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            if fields.count > 1, pid_t(fields[1]) == pid { kids.append(child) }
        }
        return kids
        #else
        // macOS：用系统自带的 pgrep，只在取消任务时调用。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        #endif
    }
}

/// 记录所有正在运行的子进程，以及它们没完成的输出文件。
/// 退出 App 时调用 `terminateAll()`，保证不留下子进程和半成品文件。
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()

    private let lock = NSLock()
    private var entries: [pid_t: [URL]] = [:]

    public init() {}

    func register(_ pid: pid_t, partialOutputs: [URL]) {
        lock.lock()
        entries[pid] = partialOutputs
        lock.unlock()
    }

    func unregister(_ pid: pid_t) {
        lock.lock()
        entries[pid] = nil
        lock.unlock()
    }

    public var activePIDs: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.keys)
    }

    /// 同步结束所有子进程（含子孙进程），并删除它们没完成的输出文件。
    public func terminateAll(grace: TimeInterval = 1.0) {
        lock.lock()
        let snapshot = entries
        entries.removeAll()
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        ProcessKiller.terminateTrees(Array(snapshot.keys), grace: grace)
        for url in snapshot.values.joined() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
