import Foundation

/// 外部进程运行一次的结果。
public struct ProcessResult: Sendable {
    public let command: Command
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    /// stderr 太长时只保留了末尾部分。
    public let stderrTruncated: Bool

    public init(command: Command, exitCode: Int32, stdout: Data, stderr: Data, stderrTruncated: Bool = false) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.stderrTruncated = stderrTruncated
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    /// “复制完整命令和日志”按钮复制的内容。
    public var fullLog: String {
        var s = "$ \(command.displayString)\n退出码：\(exitCode)\n"
        if !stderr.isEmpty {
            s += "\n--- stderr\(stderrTruncated ? "（只保留末尾）" : "") ---\n\(stderrText)"
            if !s.hasSuffix("\n") { s += "\n" }
        }
        if !stdout.isEmpty, stdout.count <= 64 * 1024 {
            s += "\n--- stdout ---\n\(stdoutText)"
            if !s.hasSuffix("\n") { s += "\n" }
        }
        return s
    }
}

/// 外部工具相关的错误，`errorDescription` 是给用户看的简单中文说明。
public enum ToolError: Error, Sendable, LocalizedError {
    case toolNotFound(Tool)
    case launchFailed(command: Command, reason: String)
    case nonZeroExit(ProcessResult)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "找不到 \(tool.executableName)。请先安装：\(tool.installHint)"
        case .launchFailed(let command, let reason):
            return "无法启动 \(command.executable.lastPathComponent)：\(reason)"
        case .nonZeroExit(let result):
            let name = result.command.executable.lastPathComponent
            let lastLine = result.stderrText
                .split(whereSeparator: \.isNewline)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init)
            if let lastLine {
                return "\(name) 运行失败（退出码 \(result.exitCode)）：\(lastLine)"
            }
            return "\(name) 运行失败（退出码 \(result.exitCode)）"
        }
    }

    /// 完整命令和日志；没有时为 nil。
    public var fullLog: String? {
        switch self {
        case .toolNotFound: return nil
        case .launchFailed(let command, let reason): return "$ \(command.displayString)\n\(reason)\n"
        case .nonZeroExit(let result): return result.fullLog
        }
    }
}
