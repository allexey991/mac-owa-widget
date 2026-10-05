import Foundation

/// The six read-only MCP tools, implemented over `CalendarService`.
///
/// Everything except meeting details reads the in-memory calendar: no network, no load on
/// Exchange. Data is limited to the sync window (start of day -7 days ... now +30 days), and every
/// answer says how fresh it is (`data_as_of`, `coverage`, `sync_state`), because `events` may come
/// from a days-old disk cache or survive a failed sync.
@MainActor
final class MCPCalendarTools {
    static let maxNetworkRequestsPerPersonSearch = 40
    static let maxBodyCharacters = 8_000

    private let calendarService: CalendarService
    private let accessGuard: MCPAccessGuard
    private let detailsCache: MCPEventDetailsCache
    private let clock: () -> Date
    private let isEnabled: () -> Bool
    private let timeZoneProvider: () -> TimeZone

    init(
        calendarService: CalendarService,
        accessGuard: MCPAccessGuard? = nil,
        detailsCache: MCPEventDetailsCache = MCPEventDetailsCache(),
        clock: @escaping () -> Date = { Date() },
        timeZone: @escaping () -> TimeZone = { AppTimeZone.zone },
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.calendarService = calendarService
        self.accessGuard = accessGuard ?? MCPAccessGuard(calendarService: calendarService, clock: clock)
        self.detailsCache = detailsCache
        self.clock = clock
        self.timeZoneProvider = timeZone
        self.isEnabled = isEnabled
    }

    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        guard isEnabled() else {
            return .failure("Access for AI assistants is turned off in OWA Widget (Settings → MCP). Ask the user to turn it on.")
        }
        let context = CallContext(now: clock(), coder: MCPDateCoder(timeZone: timeZoneProvider()))
        do {
            switch name {
            case "get_status": return getStatus(context)
            case "get_current_and_next": return try getCurrentAndNext(arguments, context)
            case "list_events": return try listEvents(arguments, context)
            case "get_schedule_stats": return try getScheduleStats(arguments, context)
            case "find_events_with_person": return try await findEventsWithPerson(arguments, context)
            case "get_event_details": return try await getEventDetails(arguments, context)
            default: return .failure("Unknown tool: \(name)")
            }
        } catch let error as ArgumentError {
            return .failure(error.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - get_status

    private func getStatus(_ context: CallContext) -> MCPToolResult {
        var result = commonFields(context)
        result["accounts"] = .array(calendarService.accounts.map { account in
            [
                "account_id": .string(account.id.uuidString),
                "name": .string(account.displayName),
                "type": .string(Self.accountTypeName(account.accountType)),
            ]
        })
        return .success(result)
    }

    // MARK: - get_current_and_next

    private func getCurrentAndNext(_ arguments: [String: JSONValue], _ context: CallContext) throws -> MCPToolResult {
        let accountID = try optionalAccountID(arguments)
        let now = context.now
        let relevant = calendarService.events.filter {
            (accountID == nil || $0.accountID == accountID)
                && !$0.isEffectivelyCancelled
                && $0.responseType != .declined
        }
        let current = relevant
            .filter { !$0.isAllDay && NextMeetingGroupPolicy.isHappening($0, now: now) }
            .sorted { $0.startDate < $1.startDate }
        let next = NextMeetingGroupPolicy.upcomingGroup(from: relevant, now: now)
        let todayStart = context.coder.calendar.startOfDay(for: now)
        let tomorrowStart = context.coder.calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let allDayToday = relevant.filter { $0.isAllDay && $0.startDate < tomorrowStart && $0.endDate > todayStart }

        var result = commonFields(context)
        result["current"] = .array(current.map { .object(eventFields($0, context)) })
        result["next"] = .array(next.map { .object(eventFields($0, context)) })
        result["all_day_today"] = .array(allDayToday.map { .object(eventFields($0, context)) })
        if current.isEmpty, let first = next.first {
            result["free_until"] = .string(context.coder.string(first.startDate))
        } else {
            result["free_until"] = .null
        }
        if let first = next.first {
            result["minutes_until_next"] = .int(Int64(max(0, first.startDate.timeIntervalSince(now)) / 60))
        }
        if next.isEmpty {
            result["note"] = "No upcoming meetings until the end of the available period (coverage.to)."
        }
        return .success(result)
    }

    // MARK: - list_events

    private func listEvents(_ arguments: [String: JSONValue], _ context: CallContext) throws -> MCPToolResult {
        let todayStart = context.coder.calendar.startOfDay(for: context.now)
        let today = DateInterval(start: todayStart, end: context.coder.calendar.date(byAdding: .day, value: 1, to: todayStart) ?? context.now)
        let resolved = try resolveRange(arguments, default: today, spanWhenOnlyFrom: .day, context)
        let accountID = try optionalAccountID(arguments)
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let responses = try responseFilter(arguments["response"])
        let includeCancelled = try optionalBool(arguments, "include_cancelled") ?? false
        let includeAllDay = try optionalBool(arguments, "include_all_day") ?? true
        let limit = try optionalInt(arguments, "limit", range: 1...300) ?? 100

        let matching = calendarService.events
            .filter { Self.overlaps($0, resolved.range) }
            .filter { accountID == nil || $0.accountID == accountID }
            .filter { includeCancelled || !$0.isEffectivelyCancelled }
            .filter { includeAllDay || !$0.isAllDay }
            .filter { responses.contains($0.responseType) }
            .filter { event in
                guard let query, !query.isEmpty else { return true }
                return [event.title, event.location, event.organizer].contains {
                    $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            .sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }

        var result = commonFields(context)
        result["range"] = rangeJSON(resolved, context)
        result["events"] = .array(matching.prefix(limit).map { .object(eventFields($0, context)) })
        result["total"] = .int(Int64(matching.count))
        result["truncated"] = .bool(matching.count > limit)
        return .success(result)
    }

    // MARK: - get_schedule_stats

    private func getScheduleStats(_ arguments: [String: JSONValue], _ context: CallContext) throws -> MCPToolResult {
        let calendar = context.coder.calendar
        let todayStart = calendar.startOfDay(for: context.now)
        // Current week, Monday to Sunday.
        let mondayOffset = (calendar.component(.weekday, from: todayStart) + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -mondayOffset, to: todayStart) ?? todayStart
        let week = DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart) ?? context.now)
        let resolved = try resolveRange(arguments, default: week, spanWhenOnlyFrom: .week, context)
        let accountID = try optionalAccountID(arguments)

        var options = ScheduleStatsCalculator.Options()
        if let text = arguments["work_start"]?.stringValue {
            guard let minute = MCPDateCoder.minuteOfDay(text) else { throw ArgumentError("`work_start` must be HH:mm") }
            options.workStartMinute = minute
        }
        if let text = arguments["work_end"]?.stringValue {
            guard let minute = MCPDateCoder.minuteOfDay(text) else { throw ArgumentError("`work_end` must be HH:mm") }
            options.workEndMinute = minute
        }
        guard options.workEndMinute > options.workStartMinute else {
            throw ArgumentError("`work_end` must be later than `work_start`")
        }
        if let days = arguments["work_days"] {
            guard let array = days.arrayValue else { throw ArgumentError("`work_days` must be an array like [\"mon\", \"tue\"]") }
            options.workDays = try Set(array.map { value in
                guard let name = value.stringValue?.lowercased(), let weekday = Self.weekdays[name] else {
                    throw ArgumentError("Unknown day in `work_days`; use mon, tue, wed, thu, fri, sat, sun")
                }
                return weekday
            })
        }
        options.minFocusMinutes = try optionalInt(arguments, "min_focus_minutes", range: 15...480) ?? 60
        options.countUnanswered = try optionalBool(arguments, "count_unanswered") ?? true

        let events = calendarService.events.filter { accountID == nil || $0.accountID == accountID }
        let stats = ScheduleStatsCalculator.compute(events: events, range: resolved.range, calendar: calendar, options: options)
        let coder = context.coder

        var result = commonFields(context)
        result["range"] = rangeJSON(resolved, context)
        result["totals"] = [
            "meeting_count": .int(Int64(stats.meetingCount)),
            "meeting_minutes": .int(Self.minutes(stats.meetingSeconds)),
            "work_minutes": .int(Self.minutes(stats.workSeconds)),
            "meeting_minutes_in_work_hours": .int(Self.minutes(stats.meetingSecondsInWorkHours)),
            "meeting_share_of_work_time": .double((stats.meetingShareOfWorkTime * 100).rounded() / 100),
            "overlap_count": .int(Int64(stats.overlapCount)),
            "all_day_count": .int(Int64(stats.allDayCount)),
            "focus_block_count": .int(Int64(stats.focusBlockCount)),
            "focus_minutes": .int(Self.minutes(stats.focusSeconds)),
        ]
        result["days"] = .array(stats.days.map { day in
            var fields: [String: JSONValue] = [
                "date": .string(coder.dayString(day.date)),
                "meeting_count": .int(Int64(day.meetingCount)),
                "meeting_minutes": .int(Self.minutes(day.meetingSeconds)),
                "work_minutes": .int(Self.minutes(day.workSeconds)),
                "longest_free_minutes_in_work_hours": .int(Self.minutes(day.longestFreeSecondsInWorkHours)),
                "back_to_back_count": .int(Int64(day.backToBackCount)),
                "first_start": day.firstStart.map { .string(coder.string($0)) } ?? .null,
                "last_end": day.lastEnd.map { .string(coder.string($0)) } ?? .null,
            ]
            if day.isPartial { fields["partial"] = true }
            return .object(fields)
        })
        result["overlaps"] = .array(stats.overlaps.map { overlap in
            [
                "event_ids": [.string(MCPEventID.short(overlap.firstID)), .string(MCPEventID.short(overlap.secondID))],
                "start": .string(coder.string(overlap.interval.start)),
                "end": .string(coder.string(overlap.interval.end)),
            ]
        })
        result["focus_blocks"] = .array(stats.focusBlocks.map { block in
            [
                "start": .string(coder.string(block.start)),
                "end": .string(coder.string(block.end)),
                "minutes": .int(Self.minutes(block.duration)),
            ]
        })
        result["options"] = [
            "work_start": .string(Self.hhmm(options.workStartMinute)),
            "work_end": .string(Self.hhmm(options.workEndMinute)),
            "work_days": .array(Self.weekdayOrder.filter { options.workDays.contains(Self.weekdays[$0]!) }.map(JSONValue.string)),
            "min_focus_minutes": .int(Int64(options.minFocusMinutes)),
            "count_unanswered": .bool(options.countUnanswered),
        ]
        return .success(result)
    }

    // MARK: - find_events_with_person

    private enum Direction: String { case past, upcoming, both }

    private struct PersonHit {
        let event: CalendarEvent
        let match: EventPersonMatcher.Match
    }

    private func findEventsWithPerson(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        guard let person = arguments["person"]?.stringValue, let matcher = EventPersonMatcher(query: person) else {
            throw ArgumentError("`person` is required: a name (any word order) or an email address")
        }
        let coverage = try requireCoverage()
        let resolved = try resolveRange(arguments, default: coverage, spanWhenOnlyFrom: nil, context)
        let accountID = try optionalAccountID(arguments)
        let directionText = arguments["direction"]?.stringValue ?? Direction.both.rawValue
        guard let direction = Direction(rawValue: directionText) else {
            throw ArgumentError("`direction` must be past, upcoming or both")
        }
        let limit = try optionalInt(arguments, "limit", range: 1...20) ?? 5
        let includeTitles = try optionalBool(arguments, "include_title_matches") ?? true

        let now = context.now
        let candidates = calendarService.events
            .filter { Self.overlaps($0, resolved.range) }
            .filter { accountID == nil || $0.accountID == accountID }
        // Nearest first on both sides, so "when did we last meet" is answered by a few requests.
        let past = candidates.filter { $0.startDate < now }.sorted { $0.startDate > $1.startDate }
        let upcoming = candidates.filter { $0.startDate >= now }.sorted { $0.startDate < $1.startDate }

        // An address query can only match an organizer (sync knows organizers by name) through
        // names already seen next to that address in a participant list.
        var knownNames = Set<String>()
        if matcher.isEmailQuery {
            for event in candidates {
                for attendee in localAttendees(event) ?? [] where matcher.matchesPerson(name: nil, email: attendee.email) {
                    knownNames.insert(EventPersonMatcher.normalizedName(attendee.name))
                }
            }
        }

        var sides: [(events: [CalendarEvent], index: Int, hits: [PersonHit], done: Bool, unchecked: Int)] = []
        if direction != .upcoming { sides.append((past, 0, [], false, 0)) }
        if direction != .past { sides.append((upcoming, 0, [], false, 0)) }

        var networkUsed = 0
        var blockedReason: String?
        var stopNetwork = false

        while sides.contains(where: { !$0.done }) {
            for s in sides.indices where !sides[s].done {
                if sides[s].index >= sides[s].events.count || sides[s].hits.count >= limit {
                    sides[s].done = true
                    continue
                }
                let event = sides[s].events[sides[s].index]
                var attendees = localAttendees(event)

                if attendees == nil, needsNetworkForAttendees(event), !organizerMatches(event, matcher, knownNames) {
                    if stopNetwork || networkUsed >= Self.maxNetworkRequestsPerPersonSearch {
                        // Stop this side here: answering past an unchecked meeting could report a
                        // later "last time" than the real one.
                        sides[s].unchecked += sides[s].events[sides[s].index...].filter {
                            localAttendees($0) == nil && needsNetworkForAttendees($0)
                        }.count
                        sides[s].done = true
                        continue
                    }
                    networkUsed += 1
                    switch await loadAttendeesAndBody(event) {
                    case .available(let loaded, _, _):
                        attendees = loaded
                    case .unavailable(let reason, let stop):
                        if stop {
                            stopNetwork = true
                            blockedReason = reason
                            continue // retried by the branch above, which then marks the side unchecked
                        }
                        // One meeting failed to load: judge it by organizer and title only.
                        sides[s].unchecked += 1
                    }
                }

                sides[s].index += 1
                if let match = personMatch(event, attendees: attendees, matcher: matcher, knownNames: &knownNames, includeTitles: includeTitles) {
                    sides[s].hits.append(PersonHit(event: event, match: match))
                }
            }
        }

        let pastHits = direction != .upcoming ? sides[0].hits : []
        let upcomingHits = direction == .upcoming ? sides[0].hits : (direction == .both ? sides[1].hits : [])
        let unchecked = sides.reduce(0) { $0 + $1.unchecked }

        var result = commonFields(context)
        result["range"] = rangeJSON(resolved, context)
        result["past"] = .array(pastHits.map { hitJSON($0, context) })
        result["upcoming"] = .array(upcomingHits.map { hitJSON($0, context) })
        result["partial"] = .bool(unchecked > 0)
        result["unchecked_count"] = .int(Int64(unchecked))
        result["detail_requests_made"] = .int(Int64(networkUsed))
        if let blockedReason { result["blocked_reason"] = .string(blockedReason) }
        if unchecked > 0, blockedReason == nil {
            result["note"] = "Some meetings were not checked yet. Call again to continue: already checked meetings are cached."
        }

        // Several different people answered to the name: let the model ask which one.
        if !matcher.isEmailQuery {
            var people: [String: (name: String, email: String?, count: Int)] = [:]
            for hit in pastHits + upcomingHits where hit.match.role != .title {
                let key = hit.match.email?.lowercased() ?? EventPersonMatcher.normalizedName(hit.match.name ?? "")
                let entry = people[key] ?? (hit.match.name ?? "", hit.match.email, 0)
                people[key] = (entry.name, entry.email, entry.count + 1)
            }
            let withEmail = people.values.filter { $0.email != nil }
            if withEmail.count > 1 {
                result["ambiguous_people"] = .array(withEmail.sorted { $0.count > $1.count }.map {
                    ["name": .string($0.name), "email": .optional($0.email), "meetings": .int(Int64($0.count))]
                })
            }
        }
        return .success(result)
    }

    private func personMatch(
        _ event: CalendarEvent,
        attendees: [EventAttendee]?,
        matcher: EventPersonMatcher,
        knownNames: inout Set<String>,
        includeTitles: Bool
    ) -> EventPersonMatcher.Match? {
        if let attendees {
            for attendee in attendees {
                if let match = matcher.match(attendee: attendee) {
                    knownNames.insert(EventPersonMatcher.normalizedName(attendee.name))
                    return match
                }
            }
        }
        if organizerMatches(event, matcher, knownNames) {
            return EventPersonMatcher.Match(role: .organizer, name: event.organizer, email: matcher.email)
        }
        if includeTitles, matcher.matchesTitle(event.title) {
            return EventPersonMatcher.Match(role: .title, name: nil, email: nil)
        }
        return nil
    }

    private func organizerMatches(_ event: CalendarEvent, _ matcher: EventPersonMatcher, _ knownNames: Set<String>) -> Bool {
        !event.isOrganizer && matcher.matchesOrganizer(event.organizer, knownNames: knownNames)
    }

    private func hitJSON(_ hit: PersonHit, _ context: CallContext) -> JSONValue {
        var fields = eventFields(hit.event, context)
        fields["match"] = .string(hit.match.role.rawValue)
        if hit.match.role != .title {
            fields["matched_person"] = ["name": .optional(hit.match.name), "email": .optional(hit.match.email)]
        }
        return .object(fields)
    }

    // MARK: - get_event_details

    private func getEventDetails(_ arguments: [String: JSONValue], _ context: CallContext) async throws -> MCPToolResult {
        guard let handle = arguments["event_id"]?.stringValue, !handle.isEmpty else {
            throw ArgumentError("`event_id` is required (take it from list_events)")
        }
        guard let event = MCPEventID.resolve(handle, in: calendarService.events) else {
            return .failure("Event \(handle) not found. It may have been removed, or the calendar was refreshed — call list_events again.")
        }

        var result = commonFields(context)
        result.merge(eventFields(event, context)) { _, new in new }
        result["join_url"] = .optional(event.joinURLForActions?.absoluteString)

        switch await loadAttendeesAndBody(event) {
        case .available(let attendees, let body, let source):
            result["attendees"] = .array(attendees.map { attendee in
                [
                    "name": .string(attendee.name),
                    "email": .optional(attendee.email),
                    "kind": .string(attendee.kind.rawValue),
                    "response": .string(Self.responseName(attendee.response)),
                ]
            })
            let text = (body ?? event.displayBody)?.trimmingCharacters(in: .whitespacesAndNewlines)
            setBody(text, into: &result)
            result["details_source"] = .string(source)
        case .unavailable(let reason, _):
            setBody(event.displayBody, into: &result)
            result["details_unavailable_reason"] = .string(reason)
        }
        return .success(result)
    }

    private func setBody(_ text: String?, into result: inout [String: JSONValue]) {
        guard let text, !text.isEmpty else {
            result["body"] = .null
            return
        }
        if text.count > Self.maxBodyCharacters {
            result["body"] = .string(String(text.prefix(Self.maxBodyCharacters)))
            result["body_truncated"] = true
        } else {
            result["body"] = .string(text)
        }
    }

    // MARK: - Details loading

    private enum DetailsOutcome {
        case available(attendees: [EventAttendee], body: String?, source: String)
        /// `stop`: no further detail requests should be attempted in this call.
        case unavailable(reason: String, stop: Bool)
    }

    /// Attendees known without a request: EventKit events arrive with them, Exchange ones only
    /// after a `GetCalendarEvent`.
    private func localAttendees(_ event: CalendarEvent) -> [EventAttendee]? {
        event.detailedAttendees ?? detailsCache.entry(for: event)?.attendees
    }

    private func needsNetworkForAttendees(_ event: CalendarEvent) -> Bool {
        // Cancelled and all-day entries are almost never what the question is about, and would
        // eat the request budget.
        guard !event.isEffectivelyCancelled, !event.isAllDay else { return false }
        return calendarService.accountType(for: event.accountID) == .owa
    }

    private func loadAttendeesAndBody(_ event: CalendarEvent) async -> DetailsOutcome {
        if let attendees = event.detailedAttendees {
            let local = calendarService.accountType(for: event.accountID) == .eventKit
            return .available(attendees: attendees, body: event.fullBody, source: local ? "local" : "cache")
        }
        if let cached = detailsCache.entry(for: event) {
            return .available(attendees: cached.attendees, body: cached.body, source: "cache")
        }
        if let denial = accessGuard.permitRequest() {
            return .unavailable(reason: denial.message, stop: true)
        }
        await accessGuard.acquireSlot()
        defer { accessGuard.releaseSlot() }
        do {
            let details = try await calendarService.loadDetails(for: event)
            detailsCache.store(details, for: event)
            return .available(attendees: details.attendees, body: details.body, source: "network")
        } catch {
            accessGuard.report(error)
            if case CalendarProviderError.notSupported = error {
                return .unavailable(reason: "This calendar does not provide meeting details.", stop: false)
            }
            if let reason = MCPAccessGuard.blockReason(calendarService.syncStatus) {
                return .unavailable(reason: reason, stop: true)
            }
            MCPDebugLog.log("details request failed: \(error.localizedDescription)")
            return .unavailable(reason: "Could not load meeting details: \(error.localizedDescription)", stop: false)
        }
    }

    // MARK: - Shared fields

    private struct CallContext {
        let now: Date
        let coder: MCPDateCoder
    }

    private struct ResolvedRange {
        let range: DateInterval
        let clipped: Bool
    }

    private enum DefaultSpan { case day, week }

    struct ArgumentError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func commonFields(_ context: CallContext) -> [String: JSONValue] {
        let coder = context.coder
        var fields: [String: JSONValue] = [
            "now": .string(coder.string(context.now)),
            "timezone": .string(coder.timeZone.identifier),
        ]
        if let coverage = calendarService.eventCoverage {
            fields["coverage"] = ["from": .string(coder.string(coverage.start)), "to": .string(coder.string(coverage.end))]
            fields["data_as_of"] = .string(coder.string(coverage.refreshedAt))
        } else {
            fields["coverage"] = .null
            fields["data_as_of"] = .null
        }
        let (state, detail) = Self.syncState(calendarService.syncStatus)
        fields["sync_state"] = .string(state)
        if let detail { fields["sync_detail"] = .string(detail) }
        return fields
    }

    private func eventFields(_ event: CalendarEvent, _ context: CallContext) -> [String: JSONValue] {
        let coder = context.coder
        var fields: [String: JSONValue] = [
            "event_id": .string(MCPEventID.short(event.id)),
            "title": .string(event.title),
            "start": .string(coder.string(event.startDate)),
            "end": .string(coder.string(event.endDate)),
            "all_day": .bool(event.isAllDay),
            "my_response": .string(Self.responseName(event.responseType)),
            "is_organizer": .bool(event.isOrganizer),
            "cancelled": .bool(event.isEffectivelyCancelled),
            "has_join_url": .bool(event.joinURLForActions != nil),
            "account_id": .string(event.accountID.uuidString),
        ]
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            fields["location"] = .string(location)
        }
        if let organizer = event.organizer, !organizer.isEmpty {
            fields["organizer"] = .string(organizer)
        }
        if event.joinURLForActions != nil {
            fields["platform"] = .string(event.platform.rawValue)
        }
        return fields
    }

    private func rangeJSON(_ resolved: ResolvedRange, _ context: CallContext) -> JSONValue {
        [
            "from": .string(context.coder.string(resolved.range.start)),
            "to": .string(context.coder.string(resolved.range.end)),
            "clipped_to_coverage": .bool(resolved.clipped),
        ]
    }

    private func requireCoverage() throws -> DateInterval {
        guard let coverage = calendarService.eventCoverage else {
            throw ArgumentError("No calendar data yet: OWA Widget has not synced. Check get_status.")
        }
        return coverage.interval
    }

    private func resolveRange(
        _ arguments: [String: JSONValue],
        default defaultRange: DateInterval,
        spanWhenOnlyFrom: DefaultSpan?,
        _ context: CallContext
    ) throws -> ResolvedRange {
        let coverage = try requireCoverage()
        let coder = context.coder
        var from = try arguments["from"]?.stringValue.map { text -> Date in
            guard let date = coder.parse(text, as: .start) else { throw ArgumentError("Invalid `from`: use YYYY-MM-DD or ISO 8601") }
            return date
        }
        var to = try arguments["to"]?.stringValue.map { text -> Date in
            guard let date = coder.parse(text, as: .end) else { throw ArgumentError("Invalid `to`: use YYYY-MM-DD or ISO 8601") }
            return date
        }
        let spanDays = spanWhenOnlyFrom.map { $0 == .day ? 1 : 7 }
        if to == nil, let from, let spanDays {
            let start = coder.calendar.startOfDay(for: from)
            to = coder.calendar.date(byAdding: .day, value: spanDays, to: start)
        }
        // Only `to` given ("what did I have until Saturday"): the same span, ending there.
        // Falling back to today's start instead put `from` after `to` for any past date.
        if from == nil, let to {
            if let spanDays {
                let lastDay = coder.calendar.startOfDay(for: to.addingTimeInterval(-1))
                from = coder.calendar.date(byAdding: .day, value: 1 - spanDays, to: lastDay)
            } else {
                from = coverage.start
            }
        }
        let start = from ?? defaultRange.start
        let end = to ?? (from == nil ? defaultRange.end : coverage.end)
        guard end > start else { throw ArgumentError("`to` must be later than `from`") }

        let clippedStart = max(start, coverage.start)
        let clippedEnd = min(end, coverage.end)
        guard clippedEnd > clippedStart else {
            throw ArgumentError(
                "No data for that period. OWA Widget only holds meetings from \(coder.string(coverage.start)) to \(coder.string(coverage.end))."
            )
        }
        return ResolvedRange(
            range: DateInterval(start: clippedStart, end: clippedEnd),
            clipped: clippedStart != start || clippedEnd != end
        )
    }

    private func optionalAccountID(_ arguments: [String: JSONValue]) throws -> UUID? {
        guard let text = arguments["account_id"]?.stringValue else { return nil }
        guard let id = UUID(uuidString: text) else { throw ArgumentError("`account_id` must be an account_id from get_status") }
        return id
    }

    private func optionalBool(_ arguments: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let bool = value.boolValue else { throw ArgumentError("`\(key)` must be true or false") }
        return bool
    }

    private func optionalInt(_ arguments: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let int = value.intValue, range.contains(int) else {
            throw ArgumentError("`\(key)` must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return int
    }

    private func responseFilter(_ value: JSONValue?) throws -> Set<MeetingResponseType> {
        guard let value, value != .null else {
            return [.accepted, .tentative, .notResponded, .organizer]
        }
        let names: [JSONValue] = value.arrayValue ?? [value]
        return try Set(names.map { name in
            guard let text = name.stringValue, let type = Self.responseTypes[text] else {
                throw ArgumentError("`response` values: accepted, tentative, not_responded, declined, organizer")
            }
            return type
        })
    }

    private static func overlaps(_ event: CalendarEvent, _ range: DateInterval) -> Bool {
        if event.endDate <= event.startDate {
            return event.startDate >= range.start && event.startDate < range.end
        }
        return event.startDate < range.end && event.endDate > range.start
    }

    // MARK: - Names

    private static let responseTypes: [String: MeetingResponseType] = [
        "accepted": .accepted, "tentative": .tentative, "not_responded": .notResponded,
        "declined": .declined, "organizer": .organizer,
    ]

    static func responseName(_ type: MeetingResponseType) -> String {
        switch type {
        case .accepted: "accepted"
        case .tentative: "tentative"
        case .notResponded: "not_responded"
        case .declined: "declined"
        case .organizer: "organizer"
        }
    }

    static func accountTypeName(_ type: AccountType) -> String {
        switch type {
        case .owa: "exchange"
        case .eventKit: "macos_calendar"
        case .googleCalendar: "google_calendar"
        }
    }

    static func syncState(_ status: SyncStatus) -> (String, String?) {
        switch status {
        case .idle: ("idle", nil)
        case .syncing: ("syncing", nil)
        case .lastSynced: ("ok", nil)
        case .offlineCached(let message): ("offline_cached", "Last sync failed, showing saved data: \(message)")
        case .error(let message): ("error", message)
        case .authenticationRequired, .certificateTrustRequired, .loginHostApprovalRequired:
            (Self.blockedStateName(status), MCPAccessGuard.blockReason(status))
        }
    }

    private static func blockedStateName(_ status: SyncStatus) -> String {
        switch status {
        case .authenticationRequired: "auth_required"
        case .certificateTrustRequired: "certificate_untrusted"
        default: "login_host_approval_required"
        }
    }

    private static let weekdays: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
    private static let weekdayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    private static func minutes(_ seconds: TimeInterval) -> Int64 {
        Int64((seconds / 60).rounded())
    }

    private static func hhmm(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
