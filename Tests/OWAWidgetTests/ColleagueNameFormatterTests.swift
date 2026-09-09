import XCTest
@testable import OWAWidget

/// Row names come from Exchange in full official form and have to survive a 420-point popover.
final class ColleagueNameFormatterTests: XCTestCase {
    func testFullRussianNameKeepsSurnameAndInitials() {
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("Юшина Оксана Владимировна"), "Юшина О.В.")
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("Аниканов Алексей Геннадьевич"), "Аниканов А.Г.")
    }

    func testTwoPartNameGetsOneInitial() {
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("Анна Ковалёва"), "Анна К.")
    }

    func testAlreadyAbbreviatedNameIsLeftAlone() {
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("Юшина О.В."), "Юшина О.В.")
    }

    func testSingleWordAndEmptyInputSurvive() {
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("Юшина"), "Юшина")
        XCTAssertEqual(ColleagueNameFormatter.abbreviated(""), "")
    }

    func testExtraPartsBeyondTheFirstTwoAreDropped() {
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("Иванова-Петрова Мария Ивановна Сергеевна"), "Иванова-Петрова М.И.")
    }

    func testSurroundingSpacesDoNotProduceEmptyInitials() {
        XCTAssertEqual(ColleagueNameFormatter.abbreviated("  Котов   Александр  "), "Котов А.")
    }
}
