import Foundation

/// 一个外部工具的检查结果。
public struct ToolStatus: Sendable, Codable, Equatable, Identifiable {
    public var tool: Tool
    public var path: String?
    public var version: String?

    public var id: Tool { tool }
    public var isAvailable: Bool { path != nil }
}

public enum ToolInventory {
    /// 查找每个工具并读取版本号。只在需要时调用一次（例如启动时、`skimcut tools`）。
    public static func check(
        locator: ToolLocator = .shared,
        runner: ToolRunner = ToolRunner()
    ) async -> [ToolStatus] {
        var result: [ToolStatus] = []
        for tool in Tool.allCases {
            guard let cmd = try? locator.command(tool, tool.versionArguments) else {
                result.append(ToolStatus(tool: tool))
                continue
            }
            // 有些工具（例如 macOS 自带的 iconv）打印版本后退出码不为 0，所以不要求退出码。
            var text = ""
            do {
                let r = try await runner.run(cmd)
                text = r.stdoutText + r.stderrText
            } catch let ToolError.nonZeroExit(r) {
                text = r.stdoutText + r.stderrText
            } catch {}
            result.append(ToolStatus(tool: tool, path: cmd.executable.path, version: Tool.parseVersion(text)))
        }
        return result
    }
}
