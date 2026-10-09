import Foundation
import XCTest
@testable import SkimCore

final class CommandTests: XCTestCase {
    func testShellQuoteLeavesSafeArgumentsAlone() {
        XCTAssertEqual(Command.shellQuote("-c:v"), "-c:v")
        XCTAssertEqual(Command.shellQuote("/usr/bin/ffmpeg"), "/usr/bin/ffmpeg")
        XCTAssertEqual(Command.shellQuote("pipe:1"), "pipe:1")
    }

    func testShellQuoteQuotesSpacesQuotesAndEmpty() {
        XCTAssertEqual(Command.shellQuote(""), "''")
        XCTAssertEqual(Command.shellQuote("my video.mp4"), "'my video.mp4'")
        XCTAssertEqual(Command.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(Command.shellQuote("中文.mp4"), "'中文.mp4'")
        XCTAssertEqual(Command.shellQuote("$HOME"), "'$HOME'")
    }

    func testDisplayStringIncludesEnvironment() {
        let cmd = Command(
            executable: URL(fileURLWithPath: "/x/ffmpeg-normalize"),
            arguments: ["in put.mp4", "-o", "out.mp4"],
            environment: ["FFMPEG_PATH": "/opt/homebrew/bin/ffmpeg"]
        )
        XCTAssertEqual(cmd.displayString,
                       "FFMPEG_PATH=/opt/homebrew/bin/ffmpeg /x/ffmpeg-normalize 'in put.mp4' -o out.mp4")
    }
}

final class ToolVersionTests: XCTestCase {
    func testParsesKnownVersionOutputs() {
        XCTAssertEqual(Tool.parseVersion("ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023"), "6.1.1-3ubuntu5")
        XCTAssertEqual(Tool.parseVersion("ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers"), "7.1.1")
        XCTAssertEqual(Tool.parseVersion("12.76\n"), "12.76")
        XCTAssertEqual(Tool.parseVersion("mkvpropedit v82.0 ('I'm The President') 64-bit"), "82.0")
        XCTAssertEqual(Tool.parseVersion("uchardet Command Line Tool\nVersion 0.0.8\n"), "0.0.8")
        XCTAssertEqual(Tool.parseVersion("ffmpeg-normalize v1.42.0"), "1.42.0")
        XCTAssertEqual(Tool.parseVersion("iconv (GNU libiconv 1.11)"), "1.11")
        XCTAssertNil(Tool.parseVersion("no version here"))
    }

    func testFFmpegNormalizeCommandGetsFFmpegPath() throws {
        let dir = try TestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["ffmpeg", "ffmpeg-normalize"] {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let locator = ToolLocator(searchDirectories: [dir], useShellFallback: false)
        let cmd = try locator.command(.ffmpegNormalize, ["in.mp4"])
        XCTAssertEqual(cmd.executable.path, dir.appendingPathComponent("ffmpeg-normalize").path)
        XCTAssertEqual(cmd.environment["FFMPEG_PATH"], dir.appendingPathComponent("ffmpeg").path)

        let plain = try locator.command(.ffmpeg, ["-version"])
        XCTAssertEqual(plain.environment, ["LC_ALL": ToolLocator.utf8Locale])
    }
}

final class LineSplitterTests: XCTestCase {
    func testSplitsOnAllNewlineKindsAcrossChunks() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(Data("a=1\nb=".utf8)), ["a=1"])
        XCTAssertEqual(s.feed(Data("2\r\nc=3\rd".utf8)), ["b=2", "c=3"])
        XCTAssertEqual(s.finish(), ["d"])
        XCTAssertEqual(s.finish(), [])
    }

    func testDoesNotBreakMultibyteCharacters() {
        var s = LineSplitter()
        let bytes = Array("中文行\n".utf8)
        var lines: [String] = []
        for b in bytes { lines += s.feed(Data([b])) }
        XCTAssertEqual(lines, ["中文行"])
    }
}

final class FFmpegProgressTests: XCTestCase {
    func testParsesProgressBlocks() {
        var p = FFmpegProgressParser()
        let input = """
        frame=60
        fps=0.00
        out_time_us=2000000
        out_time_ms=2000000
        out_time=00:00:02.000000
        total_size=1024
        speed=4.01x
        progress=continue
        frame=120
        out_time_us=N/A
        out_time=00:00:04.500000
        speed=N/A
        progress=end
        """
        let snaps = input.split(separator: "\n").compactMap { p.consume(line: String($0)) }
        XCTAssertEqual(snaps.count, 2)
        XCTAssertEqual(snaps[0], FFmpegProgress(outTime: 2, frame: 60, speed: 4.01, totalSize: 1024, isEnd: false))
        XCTAssertEqual(snaps[0].fraction(totalDuration: 8), 0.25)
        XCTAssertEqual(snaps[1].outTime, 4.5)
        XCTAssertNil(snaps[1].speed)
        XCTAssertTrue(snaps[1].isEnd)
        XCTAssertEqual(snaps[1].fraction(totalDuration: 100), 1)
    }

    func testFractionClampsAndHandlesUnknownDuration() {
        XCTAssertNil(FFmpegProgress(outTime: 3).fraction(totalDuration: nil))
        XCTAssertNil(FFmpegProgress(outTime: 3).fraction(totalDuration: 0))
        XCTAssertEqual(FFmpegProgress(outTime: 12).fraction(totalDuration: 10), 1)
        XCTAssertNil(FFmpegProgress().fraction(totalDuration: 10))
    }

    func testIgnoresNegativeStartTime() {
        var p = FFmpegProgressParser()
        _ = p.consume(line: "out_time_us=-9223372036854775807")
        XCTAssertNil(p.consume(line: "progress=continue")?.outTime)
    }
}
