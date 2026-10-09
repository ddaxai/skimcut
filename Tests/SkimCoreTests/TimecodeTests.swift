import XCTest
@testable import SkimCore

final class TimecodeTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(Timecode.format(0), "00:00:00.000")
        XCTAssertEqual(Timecode.format(83.456), "00:01:23.456")
        XCTAssertEqual(Timecode.format(3600 + 2 * 60 + 3.004), "01:02:03.004")
        XCTAssertEqual(Timecode.format(100 * 3600), "100:00:00.000")
        XCTAssertEqual(Timecode.format(-1.5), "-00:00:01.500")
        XCTAssertEqual(Timecode.format(.nan), "--:--:--.---")
    }

    func testFormatRoundsBeforeSplitting() {
        // 59.9996 四舍五入到毫秒是 60.000，不能显示成 00:00:59.1000。
        XCTAssertEqual(Timecode.format(59.9996), "00:01:00.000")
        XCTAssertEqual(Timecode.format(0.0005), "00:00:00.001")
        XCTAssertEqual(Timecode.format(1.0 / 3.0), "00:00:00.333")
    }

    func testParseAcceptedForms() throws {
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("83.456")), 83.456, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("1:23.456")), 83.456, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("00:01:23.456")), 83.456, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse(" 01:00:00 ")), 3600, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("00:00:01,500")), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("90")), 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse("125:00.5")), 7500.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Timecode.parse(".5")), 0.5, accuracy: 1e-9)
    }

    func testParseRejectsInvalid() {
        for bad in ["", " ", "abc", "1:2:3:4", "1:60", "1:61:00", "-5", "1.2.3", "1.5:00", "1::2", ":30", "1:", "１:23"] {
            XCTAssertNil(Timecode.parse(bad), bad)
        }
    }

    func testRoundTrip() throws {
        for t in [0.0, 0.001, 12.345, 83.456, 3599.999, 7322.5] {
            XCTAssertEqual(try XCTUnwrap(Timecode.parse(Timecode.format(t))), t, accuracy: 0.0005)
        }
    }
}
