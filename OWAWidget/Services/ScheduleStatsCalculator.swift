import Foundation

/// Meeting load over a period: time in meetings, overlaps, back-to-back runs and free blocks long
/// enough to focus. Pure; the MCP `get_schedule_stats` tool is a thin wrapper around it.
///
/// - Time in meetings is the **union** of intervals: two parallel meetings cost one hour, not two.
/// - Overlap uses half-open intervals (`a.start < b.end && b.start < a.end`), the project-wide
///   rule: a meeting ending at 10:00 does not overlap one starting at 10:00.
enum ScheduleStatsCalculator {
    struct Options: Equatable, Sendable {
        /// Minutes after midnight, in the calendar's time zone.
        var workStartMinute = 9 * 60
        var workEndMinute = 18 * 60
        /// `Calendar` weekday numbers (1 = Sunday ... 7 = Saturday).
        var workDays: Set<Int> = [2, 3, 4, 5, 6]
        var minFocusMinutes = 60
        /// Unanswered invitations block time by default, as in `findFreeSlots`: the invitation is
        /// on the calendar and the person is realistically not free.
        var countUnanswered = true
        var backToBackGap: TimeInterval = 5 * 60
        var maxOverlaps = 50
        var maxFocusBlocks = 30
    }

    struct Day: Equatable, Sendable {
        let date: Date
        let window: DateInterval
        let isPartial: Bool
        let meetingCount: Int
        let meetingSeconds: TimeInterval
        let workSeconds: TimeInterval
        let meetingSecondsInWorkHours: TimeInterval
        let firstStart: Date?
        let lastEnd: Date?
        let longestFreeSecondsInWorkHours: TimeInterval
        let backToBackCount: Int
    }

    struct Overlap: Equatable, Sendable {
        let firstID: String
        let secondID: String
        let interval: DateInterval
    }

    struct Result: Equatable, Sendable {
        let range: DateInterval
        let meetingCount: Int
        let meetingSeconds: TimeInterval
        let workSeconds: TimeInterval
        let meetingSecondsInWorkHours: TimeInterval
        let overlapCount: Int
        let allDayCount: Int
        let days: [Day]
        let overlaps: [Overlap]
        let focusBlockCount: Int
        let focusSeconds: TimeInterval
        let focusBlocks: [DateInterval]

        var meetingShareOfWorkTime: Double {
            workSeconds > 0 ? meetingSecondsInWorkHours / workSeconds : 0
        }
    }

    static func compute(
        events: [CalendarEvent],
        range: DateInterval,
        calendar: Calendar,
        options: Options = Options()
    ) -> Result {
        let inRange = events.filter {
            $0.startDate < range.end && $0.endDate > range.start
                && !$0.isEffectivelyCancelled && $0.responseType != .declined
        }
        let allDayCount = inRange.filter(\.isAllDay).count
        let meetings = inRange
            .filter { !$0.isAllDay && $0.endDate > $0.startDate }
            .filter { options.countUnanswered || $0.responseType != .notResponded }
            .sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }

        var days: [Day] = []
        var focusBlocks: [DateInterval] = []
        var dayStart = calendar.startOfDay(for: range.start)
        while dayStart < range.end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let window = DateInterval(start: max(dayStart, range.start), end: min(nextDay, range.end))
            if window.duration > 0 {
                let (day, blocks) = computeDay(
                    dayStart: dayStart,
                    nextDay: nextDay,
                    window: window,
                    meetings: meetings,
                    calendar: calendar,
                    options: options
                )
                days.append(day)
                focusBlocks.append(contentsOf: blocks)
            }
            dayStart = nextDay
        }

        var overlaps: [Overlap] = []
        var overlapCount = 0
        for i in meetings.indices {
            for j in meetings.indices where j > i {
                let a = meetings[i], b = meetings[j]
                if b.startDate >= a.endDate { break }
                guard a.startDate < b.endDate && b.startDate < a.endDate else { continue }
                let start = max(a.startDate, b.startDate, range.start)
                let end = min(a.endDate, b.endDate, range.end)
                guard end > start else { continue }
                overlapCount += 1
                if overlaps.count < options.maxOverlaps {
                    overlaps.append(Overlap(firstID: a.id, secondID: b.id, interval: DateInterval(start: start, end: end)))
                }
            }
        }

        return Result(
            range: range,
            meetingCount: meetings.count,
            meetingSeconds: days.reduce(0) { $0 + $1.meetingSeconds },
            workSeconds: days.reduce(0) { $0 + $1.workSeconds },
            meetingSecondsInWorkHours: days.reduce(0) { $0 + $1.meetingSecondsInWorkHours },
            overlapCount: overlapCount,
            allDayCount: allDayCount,
            days: days,
            overlaps: overlaps,
            focusBlockCount: focusBlocks.count,
            focusSeconds: focusBlocks.reduce(0) { $0 + $1.duration },
            focusBlocks: Array(focusBlocks.prefix(options.maxFocusBlocks))
        )
    }

    private static func computeDay(
        dayStart: Date,
        nextDay: Date,
        window: DateInterval,
        meetings: [CalendarEvent],
        calendar: Calendar,
        options: Options
    ) -> (Day, [DateInterval]) {
        let dayMeetings = meetings.filter { $0.startDate < window.end && $0.endDate > window.start }
        let clipped = dayMeetings.map {
            DateInterval(start: max($0.startDate, window.start), end: min($0.endDate, window.end))
        }
        let busy = union(clipped)

        var workWindow: DateInterval?
        let weekday = calendar.component(.weekday, from: dayStart)
        if options.workDays.contains(weekday),
           options.workEndMinute > options.workStartMinute,
           let workStart = wallClock(options.workStartMinute, on: dayStart, nextDay: nextDay, calendar: calendar),
           let workEnd = wallClock(options.workEndMinute, on: dayStart, nextDay: nextDay, calendar: calendar) {
            let start = max(workStart, window.start)
            let end = min(workEnd, window.end)
            if end > start { workWindow = DateInterval(start: start, end: end) }
        }

        var free: [DateInterval] = []
        var busyInWork: TimeInterval = 0
        if let workWindow {
            var cursor = workWindow.start
            for interval in busy {
                let start = max(interval.start, workWindow.start)
                let end = min(interval.end, workWindow.end)
                guard end > start else { continue }
                busyInWork += end.timeIntervalSince(start)
                if start > cursor { free.append(DateInterval(start: cursor, end: start)) }
                cursor = max(cursor, end)
            }
            if workWindow.end > cursor { free.append(DateInterval(start: cursor, end: workWindow.end)) }
        }

        var backToBack = 0
        var runningEnd: Date?
        for meeting in dayMeetings {
            if let end = runningEnd, meeting.startDate >= end,
               meeting.startDate.timeIntervalSince(end) < options.backToBackGap {
                backToBack += 1
            }
            runningEnd = max(runningEnd ?? meeting.endDate, meeting.endDate)
        }

        let minFocus = TimeInterval(max(1, options.minFocusMinutes) * 60)
        let day = Day(
            date: dayStart,
            window: window,
            isPartial: window.start > dayStart || window.end < nextDay,
            meetingCount: dayMeetings.count,
            meetingSeconds: busy.reduce(0) { $0 + $1.duration },
            workSeconds: workWindow?.duration ?? 0,
            meetingSecondsInWorkHours: busyInWork,
            firstStart: clipped.map(\.start).min(),
            lastEnd: clipped.map(\.end).max(),
            longestFreeSecondsInWorkHours: free.map(\.duration).max() ?? 0,
            backToBackCount: backToBack
        )
        return (day, free.filter { $0.duration >= minFocus })
    }

    /// Wall-clock time on that day. Adding N minutes to midnight would be off by an hour on DST
    /// transition days (23- and 25-hour days). 24:00 is the start of the next day.
    private static func wallClock(_ minuteOfDay: Int, on dayStart: Date, nextDay: Date, calendar: Calendar) -> Date? {
        if minuteOfDay >= 24 * 60 { return nextDay }
        return calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: dayStart)
    }

    /// Merges overlapping or touching intervals. Input order does not matter.
    static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
