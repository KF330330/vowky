import XCTest
@testable import VowKy

final class DiarizeSubprocessProtocolTests: XCTestCase {

    // MARK: - 编解码 round-trip

    func test01_progress_roundTrip() {
        let line = DiarizeSubprocessLine.progress(processed: 23, total: 77)
        XCTAssertEqual(line.encoded, "PROGRESS 23 77")
        XCTAssertEqual(DiarizeSubprocessLine.parse(line.encoded), line)
    }

    func test02_result_roundTrip() {
        let segments = [
            DiarizeSegmentDTO(s: 0.317, e: 6.865, spk: 0),
            DiarizeSegmentDTO(s: 7.017, e: 10.746, spk: 7),
        ]
        let line = DiarizeSubprocessLine.result(segments)
        XCTAssertTrue(line.encoded.hasPrefix("RESULT {"))
        XCTAssertFalse(line.encoded.contains("\n"), "RESULT 必须单行")
        XCTAssertEqual(DiarizeSubprocessLine.parse(line.encoded), line)
    }

    func test03_emptyResult_roundTrip() {
        let line = DiarizeSubprocessLine.result([])
        XCTAssertEqual(DiarizeSubprocessLine.parse(line.encoded), line)
    }

    func test04_error_roundTrip() {
        let line = DiarizeSubprocessLine.error("model not found")
        XCTAssertEqual(line.encoded, "ERROR model not found")
        XCTAssertEqual(DiarizeSubprocessLine.parse(line.encoded), line)
    }

    func test05_error_multilineMessageFlattened() {
        let line = DiarizeSubprocessLine.error("line1\nline2\r\nline3")
        XCTAssertFalse(line.encoded.contains("\n"))
        XCTAssertFalse(line.encoded.contains("\r"))
    }

    // MARK: - 畸形行容错

    func test06_unknownLine_returnsNil() {
        XCTAssertNil(DiarizeSubprocessLine.parse("some library noise"))
        XCTAssertNil(DiarizeSubprocessLine.parse(""))
        XCTAssertNil(DiarizeSubprocessLine.parse("PROGRESSIVE 1 2"))
    }

    func test07_malformedProgress_returnsNil() {
        XCTAssertNil(DiarizeSubprocessLine.parse("PROGRESS abc 20"))
        XCTAssertNil(DiarizeSubprocessLine.parse("PROGRESS 1"))
        XCTAssertNil(DiarizeSubprocessLine.parse("PROGRESS -1 20"))
        XCTAssertNil(DiarizeSubprocessLine.parse("PROGRESS 1 2 3"))
    }

    func test08_malformedResultJSON_returnsNil() {
        XCTAssertNil(DiarizeSubprocessLine.parse("RESULT not-json"))
        XCTAssertNil(DiarizeSubprocessLine.parse("RESULT {\"wrong\":[]}"))
    }

    func test09_parse_toleratesTrailingWhitespace() {
        XCTAssertEqual(
            DiarizeSubprocessLine.parse("PROGRESS 1 2\n"),
            .progress(processed: 1, total: 2)
        )
    }
}
