import Foundation
import XCTest
@testable import SkimCore

enum TestSupport {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SkimCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    /// CI 里设置 SKIMCUT_REQUIRE_TOOLS=1：缺工具直接失败，而不是跳过。
    static var toolsRequired: Bool {
        ProcessInfo.processInfo.environment["SKIMCUT_REQUIRE_TOOLS"] == "1"
    }

    /// 找到工具；找不到时本地跳过、CI 失败。
    static func requireTool(_ tool: Tool, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        if let url = ToolLocator.shared.locate(tool) { return url }
        if toolsRequired {
            XCTFail("缺少 \(tool.rawValue)，但 SKIMCUT_REQUIRE_TOOLS=1", file: file, line: line)
            throw XCTSkip("missing \(tool.rawValue)")
        }
        throw XCTSkip("没有安装 \(tool.rawValue)，跳过集成测试")
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skimcut-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用 scripts/make-test-media.sh 生成的素材，每次测试进程只生成一次。
    static func testMedia() throws -> URL {
        _ = try requireTool(.ffmpeg)
        _ = try requireTool(.iconv)
        return try mediaResult.get()
    }

    private static let mediaResult: Result<URL, Error> = Result {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skimcut-test-media-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("scripts/make-test-media.sh").path, dir.path]
        var env = ProcessInfo.processInfo.environment
        if let ffmpeg = ToolLocator.shared.locate(.ffmpeg) { env["FFMPEG"] = ffmpeg.path }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TestMedia", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "make-test-media.sh 失败"])
        }
        return dir
    }

    /// 简单的 shell 命令（只用于测试 ToolRunner 本身）。
    static func sh(_ script: String, _ args: [String] = []) -> Command {
        Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "sh"] + args)
    }
}
