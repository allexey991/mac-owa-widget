import XCTest
@testable import OWAWidget

/// The room link is typed by hand and later handed to `NSWorkspace.open`, so it goes through the
/// same scheme check as meeting links.
final class ColleagueRoomLinkTests: XCTestCase {
    func testHTTPSLinkIsAccepted() {
        XCTAssertTrue(ColleagueRoomLink.isValid("https://teams.microsoft.com/l/meetup-join/19%3ameeting"))
        XCTAssertTrue(ColleagueRoomLink.isValid("  https://example.zoom.us/j/123456  "))
    }

    func testDangerousAndEmptySchemesAreRejected() {
        XCTAssertFalse(ColleagueRoomLink.isValid("javascript:alert(1)"))
        XCTAssertFalse(ColleagueRoomLink.isValid("file:///etc/passwd"))
        XCTAssertFalse(ColleagueRoomLink.isValid(""))
        XCTAssertFalse(ColleagueRoomLink.isValid(nil))
    }

    /// An empty field is a normal state: a colleague without a room is a row without a button.
    func testEmptyInputIsAcceptableButNotAValidLink() {
        XCTAssertTrue(ColleagueRoomLink.isAcceptableInput("   "))
        XCTAssertFalse(ColleagueRoomLink.isAcceptableInput("not a link"))
        XCTAssertFalse(ColleagueRoomLink.isAcceptableInput("комната Анны"))
    }

    /// A link pasted without the scheme still works, the way meeting links do.
    func testSchemelessHostIsUpgradedToHTTPS() {
        XCTAssertEqual(
            ColleagueRoomLink.normalized("rooms.example.com/anna")?.absoluteString,
            "https://rooms.example.com/anna"
        )
        XCTAssertEqual(
            ColleagueRoomLink.normalized("http://rooms.example.com/anna")?.absoluteString,
            "https://rooms.example.com/anna"
        )
    }

    func testPlatformIsDetectedFromTheLink() {
        XCTAssertEqual(ColleagueRoomLink.platform(for: "https://teams.microsoft.com/l/meetup-join/19%3ameeting"), .teams)
        XCTAssertEqual(ColleagueRoomLink.platform(for: "https://acme.zoom.us/j/123456789"), .zoom)
        XCTAssertEqual(ColleagueRoomLink.platform(for: "https://rooms.example.com/anna"), .generic)
    }
}
