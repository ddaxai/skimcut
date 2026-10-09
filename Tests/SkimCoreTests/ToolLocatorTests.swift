import Foundation
import XCTest
@testable import SkimCore

final class ToolLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestSupport.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> URL {
        let d = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeFile(_ name: String, in dir: URL, executable: Bool = true) throws {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    func testDefaultSearchOrder() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(ToolLocator.defaultSearchDirectories(home: home).map(\.path),
                       ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/Users/me/.local/bin"])
    }

    func testFirstDirectoryWins() throws {
        let a = try dir("a"), b = try dir("b")
        try makeFile("ffprobe", in: a)
        try makeFile("ffprobe", in: b)
        let locator = ToolLocator(searchDirectories: [a, b], useShellFallback: false)
        XCTAssertEqual(locator.locate(.ffprobe)?.path, a.appendingPathComponent("ffprobe").path)
    }

    func testFallsThroughToLaterDirectory() throws {
        let a = try dir("a"), b = try dir("b")
        try makeFile("exiftool", in: b)
        let locator = ToolLocator(searchDirectories: [a, b], useShellFallback: false)
        XCTAssertEqual(locator.locate(.exiftool)?.path, b.appendingPathComponent("exiftool").path)
    }

    func testSkipsNonExecutableFilesAndDirectories() throws {
        let a = try dir("a"), b = try dir("b")
        try makeFile("uchardet", in: a, executable: false)
        try FileManager.default.createDirectory(at: a.appendingPathComponent("ffmpeg"), withIntermediateDirectories: true)
        try makeFile("uchardet", in: b)
        let locator = ToolLocator(searchDirectories: [a, b], useShellFallback: false)
        XCTAssertEqual(locator.locate(.uchardet)?.path, b.appendingPathComponent("uchardet").path)
        XCTAssertNil(locator.locate(.ffmpeg))
    }

    func testMissingToolThrowsChineseError() throws {
        let locator = ToolLocator(searchDirectories: [try dir("empty")], useShellFallback: false)
        XCTAssertThrowsError(try locator.require(.mkvpropedit)) { error in
            guard case ToolError.toolNotFound(.mkvpropedit) = error else { return XCTFail("\(error)") }
            XCTAssertTrue((error as? ToolError)?.errorDescription?.contains("找不到 mkvpropedit") == true)
        }
    }

    func testResultsAreCached() throws {
        let a = try dir("a")
        try makeFile("ffmpeg", in: a)
        let locator = ToolLocator(searchDirectories: [a], useShellFallback: false)
        let first = locator.locate(.ffmpeg)
        try FileManager.default.removeItem(at: a.appendingPathComponent("ffmpeg"))
        XCTAssertEqual(locator.locate(.ffmpeg), first)
        locator.resetCache()
        XCTAssertNil(locator.locate(.ffmpeg))
    }

    func testShellFallbackFindsSystemCommand() throws {
        guard FileManager.default.isExecutableFile(atPath: ToolLocator.fallbackShell.path) else {
            throw XCTSkip("没有 \(ToolLocator.fallbackShell.path)")
        }
        let locator = ToolLocator(searchDirectories: [try dir("empty")], useShellFallback: true)
        let found = try XCTUnwrap(locator.locate(executableNamed: "sh"))
        XCTAssertTrue(found.path.hasSuffix("/sh"))
        XCTAssertNil(locator.locate(executableNamed: "definitely-not-a-real-tool-\(UUID().uuidString)"))
    }

    func testShellFallbackDoesNotInterpretName() throws {
        let marker = root.appendingPathComponent("pwned")
        let locator = ToolLocator(searchDirectories: [try dir("empty")], useShellFallback: true)
        XCTAssertNil(locator.locate(executableNamed: "x; touch '\(marker.path)'"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
