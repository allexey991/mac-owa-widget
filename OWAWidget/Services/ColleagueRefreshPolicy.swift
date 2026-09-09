import Foundation

/// The request window for colleague availability.
///
/// A week forward rather than a day: the response is one character per half hour per person, so a
/// week costs a few hundred bytes each, and it is what lets a row say "Нет на месте до пятницы"
/// instead of stopping at midnight.
enum ColleagueAvailabilityWindow {
    static let forwardDays = 7

    static func bounds(now: Date, calendar: Calendar = AppTimeZone.calendar) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: forwardDays, to: start) ?? now.addingTimeInterval(TimeInterval(forwardDays) * 86_400)
        return (start, end)
    }
}

/// When to spend a request, and how much to trust what is already on hand.
///
/// Kept apart from the service so the timing rules are testable without a clock, a network or an
/// Exchange account.
enum ColleagueRefreshPolicy {
    static let defaultCacheMinutes = 5
    static let cacheMinuteOptions = [2, 5, 10, 15]

    static func shouldRefresh(
        lastSuccessAt: Date?,
        now: Date,
        ttl: TimeInterval,
        isRefreshing: Bool,
        hasColleagues: Bool
    ) -> Bool {
        guard hasColleagues, !isRefreshing else { return false }
        guard let lastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= ttl
    }

    /// A grid downloaded on another day says nothing about today, no matter how recently it was
    /// fetched: the window it covers starts at that day's midnight.
    static func isWindowUsable(windowStart: Date?, now: Date, calendar: Calendar = AppTimeZone.calendar) -> Bool {
        guard let windowStart else { return false }
        return calendar.isDate(windowStart, inSameDayAs: now)
    }

    static func freshness(
        lastSuccessAt: Date?,
        lastAttemptFailed: Bool,
        windowUsable: Bool
    ) -> ColleagueDataFreshness {
        guard windowUsable, let lastSuccessAt else { return .none }
        return lastAttemptFailed ? .stale(since: lastSuccessAt) : .fresh
    }
}
