import Foundation

/// 一次外部进程调用。参数始终是数组，直接交给 `Process`，从不拼接成 shell 字符串。
public struct Command: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    /// 追加到当前进程环境变量上的值（例如 ffmpeg-normalize 的 `FFMPEG_PATH`）。
    public var environment: [String: String]
    public var workingDirectory: URL?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// 可以直接粘贴到终端运行的命令行，只用于显示和“复制完整命令和日志”。
    public var displayString: String {
        let env = environment.keys.sorted().map { "\($0)=\(Command.shellQuote(environment[$0]!))" }
        let parts = env + [Command.shellQuote(executable.path)] + arguments.map(Command.shellQuote)
        return parts.joined(separator: " ")
    }

    /// 按 POSIX shell 规则给一个参数加引号；安全字符组成的参数原样返回。
    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if s.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
