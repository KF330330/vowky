import XCTest
@testable import VowKy

final class WhatsNewWindowControllerTests: XCTestCase {

    func testFirstInstallMarksSeenWithoutShowing() {
        let decision = WhatsNewWindowController.decision(lastSeenBuild: nil, currentBuild: "19")
        XCTAssertEqual(decision, .markSeenOnly)
    }

    func testSameBuildSkips() {
        let decision = WhatsNewWindowController.decision(lastSeenBuild: "19", currentBuild: "19")
        XCTAssertEqual(decision, .skip)
    }

    func testNewBuildShowsWindow() {
        let decision = WhatsNewWindowController.decision(lastSeenBuild: "19", currentBuild: "20")
        XCTAssertEqual(decision, .showWindow)
    }

    func testEmptyCurrentBuildSkipsToAvoidAccidentalPrompts() {
        let decision = WhatsNewWindowController.decision(lastSeenBuild: "19", currentBuild: "")
        XCTAssertEqual(decision, .skip)
    }
}

final class ReleaseNotesLoaderTests: XCTestCase {

    func testMissingFileReturnsFallback() {
        // 测试 bundle 里几乎肯定没有 "0.0.0-nonexistent.md"
        let notes = ReleaseNotesLoader.load(forVersion: "0.0.0-nonexistent", bundle: .main)
        XCTAssertEqual(notes, ReleaseNotesLoader.fallbackText)
    }

    func testEmptyVersionStringReturnsFallback() {
        let notes = ReleaseNotesLoader.load(forVersion: "", bundle: .main)
        XCTAssertEqual(notes, ReleaseNotesLoader.fallbackText)
    }
}
