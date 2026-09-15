import XCTest
@testable import OWAWidget

/// Сведение занятости участников в состояние одной ячейки сетки.
///
/// Коды идут из merged free/busy Exchange: `0` свободен, `1` под вопросом, `2` занят,
/// `3` вне офиса, `4` данных нет. Первые четыре — шкала тяжести, пятый к ней не относится,
/// и именно это когда-то сломало отрисовку: `"4"` лексически больше `"3"`, поэтому один
/// участник без опубликованной занятости перекрывал реально занятых.
final class SlotAvailabilityAggregationTests: XCTestCase {

    private func isFree(_ state: SlotAvailabilityState) -> Bool {
        if case .free = state { return true }
        return false
    }

    // MARK: Обычная шкала

    func testWorstStatusWins() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: ["0", "0", "0"])))

        if case .tentative = SlotAvailabilityState.aggregate(from: ["0", "1"]) {} else {
            XCTFail("под вопросом должно перевесить свободен")
        }
        if case .busy = SlotAvailabilityState.aggregate(from: ["0", "1", "2"]) {} else {
            XCTFail("занят должен перевесить всё, кроме отсутствия")
        }
        if case .outOfOffice = SlotAvailabilityState.aggregate(from: ["0", "2", "3"]) {} else {
            XCTFail("вне офиса — худший из известных")
        }
    }

    func testEmptyInputIsFree() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: [])))
    }

    // MARK: Код «нет данных»

    /// Тот самый баг: коллега без опубликованной занятости делал слот зелёным, хотя рядом
    /// стоял реально занятый участник.
    func testNoDataDoesNotMaskABusyAttendee() {
        if case .busy = SlotAvailabilityState.aggregate(from: ["2", "4"]) {} else {
            XCTFail("«нет данных» не должно перекрывать занятость")
        }
        if case .busy = SlotAvailabilityState.aggregate(from: ["4", "4", "2", "4"]) {} else {
            XCTFail("сколько бы ни было неизвестных, занятый остаётся занятым")
        }
        if case .outOfOffice = SlotAvailabilityState.aggregate(from: ["4", "3"]) {} else {
            XCTFail("«нет данных» не должно перекрывать отсутствие в офисе")
        }
        if case .tentative = SlotAvailabilityState.aggregate(from: ["4", "1", "0"]) {} else {
            XCTFail("«нет данных» не должно перекрывать «под вопросом»")
        }
    }

    /// Когда занятость не опубликована ни у кого, известного статуса нет вовсе. Ячейка
    /// показывается свободной, но кликабельной не станет: калькулятор требует ровно `"0"`
    /// и такой слот не предложит.
    func testAllUnknownFallsBackToFree() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: ["4", "4", "4"])))
    }

    /// Неизвестные коды из будущих версий протокола не должны вести себя как занятость.
    func testUnknownCodesAreTreatedAsFreeNotAsBusy() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: ["0", "9"])))
    }
}
