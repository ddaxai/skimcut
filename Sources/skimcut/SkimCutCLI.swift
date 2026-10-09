import ArgumentParser
import Foundation
import SkimCore

@main
struct SkimCutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skimcut",
        abstract: "SkimCut 命令行工具：提供 SkimCore 的全部功能。",
        version: SkimCoreInfo.version,
        subcommands: [Tools.self]
    )
}

/// `skimcut tools`：列出每个外部工具的路径和版本。
struct Tools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "检查外部工具的位置和版本。")

    @Flag(help: "以 JSON 格式输出。")
    var json = false

    @Flag(help: "缺少任何工具时以非零状态退出。")
    var strict = false

    func run() async throws {
        let statuses = await ToolInventory.check()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(statuses), as: UTF8.self))
        } else {
            for s in statuses {
                let name = s.tool.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)
                if let path = s.path {
                    print("\(name)\(s.version ?? "?")\t\(path)")
                } else {
                    print("\(name)未找到\t安装：\(s.tool.installHint)")
                }
            }
        }
        if strict, statuses.contains(where: { !$0.isAvailable }) {
            throw ExitCode(1)
        }
    }
}
