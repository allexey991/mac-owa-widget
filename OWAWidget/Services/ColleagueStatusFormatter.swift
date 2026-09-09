import Foundation

/// Renders a ``ColleagueStatus`` as the one line shown next to a colleague's name.
///
/// Labels are fixed, not agreed with the person: the address book gives no gender, and
/// "Свободна/Свободен" would be a coin flip on every row. The line reads as a status badge
/// ("Занят до 15:00"), the way a calendar app labels a slot rather than a human.
enum ColleagueStatusFormatter {
    /// Below this, the line counts down ("ещё 40 мин"); above it, it names the hour ("до 15:00").
    static let remainingThreshold: TimeInterval = 60 * 60

    @MainActor
    static func text(
        for status: ColleagueStatus,
        now: Date,
        localization: LocalizationService,
        calendar: Calendar = AppTimeZone.calendar
    ) -> String {
        let label = localization.tr(status.presence.localizationKey)
        guard status.presence != .noData, let until = status.until, until > now else { return label }

        if calendar.isDate(until, inSameDayAs: now) {
            let remaining = until.timeIntervalSince(now)
            if remaining < remainingThreshold {
                let minutes = max(1, Int((remaining / 60).rounded(.up)))
                return localization.tr("colleagues.status.remaining", label, localization.compactDuration(minutes: minutes))
            }
            return localization.tr("colleagues.status.until.time", label, localization.shortTime(until))
        }

        return localization.tr("colleagues.status.until.day", label, weekdayName(for: until, localization: localization, calendar: calendar))
    }

    /// Weekday in the form that follows "до" in Russian ("до пятницы"), which the system
    /// formatters only produce in the nominative ("пятница"). English keeps the plain name.
    @MainActor
    static func weekdayName(for date: Date, localization: LocalizationService, calendar: Calendar) -> String {
        let weekday = calendar.component(.weekday, from: date)
        return localization.tr("colleagues.weekday.\(weekday)")
    }
}
