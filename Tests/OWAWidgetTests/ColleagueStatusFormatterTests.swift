import XCTest
@testable import OWAWidget

/// The status line is a fixed label plus a time, never agreed with the person: the address book
/// gives no gender, so "Свободна/Свободен" would be a coin flip on every row.
@MainActor
final class ColleagueStatusFormatterTests: XCTestCase {
    private let calendar = AppTimeZone.calendar

    private func russian() -> LocalizationService {
        LocalizationService(selectedLanguage: .russian, preferredLanguages: ["en-US"])
    }

    private func today(hour: Int, minute: Int = 0) -> Date {
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: base)!
    }

    func testLabelsCarryNoGender() {
        let localization = russian()

        XCTAssertEqual(localization.tr("colleagues.status.free"), "Свободен")
        XCTAssertEqual(localization.tr("colleagues.status.busy"), "Занят")
        XCTAssertEqual(localization.tr("colleagues.status.away"), "Нет на месте")
        XCTAssertEqual(localization.tr("colleagues.status.unknown"), "Нет данных")
    }

    func testStateEndingWithinAnHourCountsDown() {
        let now = today(hour: 12, minute: 20)
        let status = ColleagueStatus(presence: .free, until: today(hour: 13))

        let text = ColleagueStatusFormatter.text(for: status, now: now, localization: russian(), calendar: calendar)

        XCTAssertEqual(text, "Свободен ещё 40 мин")
    }

    func testStateEndingLaterNamesTheHour() {
        let now = today(hour: 12, minute: 20)
        let status = ColleagueStatus(presence: .busy, until: today(hour: 15))

        let text = ColleagueStatusFormatter.text(for: status, now: now, localization: russian(), calendar: calendar)

        XCTAssertTrue(text.hasPrefix("Занят до "), "Unexpected line: \(text)")
        XCTAssertTrue(text.contains("15"), "Unexpected line: \(text)")
    }

    /// Multi-day absence is why the request covers a week: stopping at midnight would print a
    /// meaningless "до 00:00".
    func testStateEndingOnAnotherDayNamesTheWeekdayInGenitive() {
        let now = today(hour: 12)
        let until = calendar.date(byAdding: .day, value: 2, to: today(hour: 9))!
        let status = ColleagueStatus(presence: .away, until: until)

        let text = ColleagueStatusFormatter.text(for: status, now: now, localization: russian(), calendar: calendar)
        let weekday = calendar.component(.weekday, from: until)

        XCTAssertEqual(text, "Нет на месте до \(russian().tr("colleagues.weekday.\(weekday)"))")
    }

    func testUnknownStateAndOpenEndedRunPrintTheBareLabel() {
        let now = today(hour: 12)

        XCTAssertEqual(
            ColleagueStatusFormatter.text(for: .unknown, now: now, localization: russian(), calendar: calendar),
            "Нет данных"
        )
        XCTAssertEqual(
            ColleagueStatusFormatter.text(
                for: ColleagueStatus(presence: .free, until: nil),
                now: now,
                localization: russian(),
                calendar: calendar
            ),
            "Свободен"
        )
    }

    func testEnglishKeepsTheSameShape() {
        let localization = LocalizationService(selectedLanguage: .english, preferredLanguages: ["ru-RU"])
        let status = ColleagueStatus(presence: .busy, until: today(hour: 15))

        let text = ColleagueStatusFormatter.text(
            for: status,
            now: today(hour: 12),
            localization: localization,
            calendar: calendar
        )

        XCTAssertTrue(text.hasPrefix("Busy until "), "Unexpected line: \(text)")
    }
}
