import Foundation
import os.log

/// Availability of the colleagues the user watches, kept for the popover's "Коллеги" section.
///
/// Deliberately not part of ``CalendarService``: it owns a different store, a different refresh
/// cadence and a different failure mode, and that service is already the largest object here.
///
/// One refresh is one request for the whole list — the Exchange call takes an array of mailboxes —
/// so adding people costs response bytes, not round trips. Between refreshes nothing is requested
/// at all: the downloaded grid covers the week, so the current status is recomputed locally from
/// the clock, and it keeps moving while offline.
@MainActor
final class ColleaguePresenceService: ObservableObject {
    @Published private(set) var colleagues: [WatchedColleague] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var freshness: ColleagueDataFreshness = .none
    /// Last successful fetch, shown in the section header once data goes stale.
    @Published private(set) var lastSuccessAt: Date?

    private var availabilities: [AttendeeAvailability] = []
    private var windowStart: Date?
    private var lastAttemptFailed = false
    private var refreshTask: Task<Void, Never>?
    private weak var calendarService: CalendarService?

    private let store: WatchedColleaguesStore.Store
    private let clock: () -> Date
    private let calendar: Calendar
    private let log = Logger(subsystem: "com.owawidget", category: "ColleaguePresence")

    init(
        store: WatchedColleaguesStore.Store = WatchedColleaguesStore.shared,
        clock: @escaping () -> Date = Date.init,
        calendar: Calendar = AppTimeZone.calendar
    ) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.colleagues = WatchedColleaguesStore.load(store: store)
    }

    /// Wires the service to the calendar stack. Called once from the app scene; safe to repeat.
    ///
    /// Announces the change: whether the section can appear at all depends on the attached
    /// service, and a view that rendered before the wiring would otherwise keep hiding it.
    func attach(_ service: CalendarService) {
        guard calendarService !== service else { return }
        objectWillChange.send()
        calendarService = service
    }

    // MARK: - Capability

    /// The account able to answer availability questions, or `nil` when none can.
    ///
    /// Read-only providers throw `notSupported`, so the section is hidden rather than left to fail
    /// on every refresh.
    var availabilityAccount: CalendarAccount? {
        calendarService?.colleagueAvailabilityAccount
    }

    var isSupported: Bool { availabilityAccount != nil }

    var isSectionVisible: Bool {
        guard let calendarService else { return false }
        return calendarService.colleaguesSectionEnabled && isSupported
    }

    // MARK: - Statuses

    func status(for colleague: WatchedColleague, now: Date) -> ColleagueStatus {
        guard ColleagueRefreshPolicy.isWindowUsable(windowStart: windowStart, now: now, calendar: calendar),
              let availability = availabilities.first(where: { $0.email.lowercased() == colleague.id })
        else { return .unknown }
        return ColleagueStatusCalculator.status(from: availability, now: now)
    }

    /// Rows in display order: free first, unknown last, ties keep the user's own ordering.
    func sortedColleagues(now: Date) -> [WatchedColleague] {
        colleagues.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = status(for: lhs.element, now: now).presence.sortRank
                let rhsRank = status(for: rhs.element, now: now).presence.sortRank
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func freeCount(now: Date) -> Int {
        colleagues.filter { status(for: $0, now: now).presence == .free }.count
    }

    // MARK: - Refreshing

    /// Called when the popover opens. Honours the cache so reopening it a dozen times in a row
    /// does not turn into a dozen requests.
    func popoverDidAppear() {
        guard let calendarService, calendarService.colleaguesRefreshOnPopoverOpen else { return }
        refreshIfStale()
    }

    func refreshIfStale() {
        let ttl = TimeInterval((calendarService?.colleaguesCacheMinutes ?? ColleagueRefreshPolicy.defaultCacheMinutes) * 60)
        let now = clock()
        let windowUsable = ColleagueRefreshPolicy.isWindowUsable(windowStart: windowStart, now: now, calendar: calendar)
        let shouldRefresh = !windowUsable || ColleagueRefreshPolicy.shouldRefresh(
            lastSuccessAt: lastSuccessAt,
            now: now,
            ttl: ttl,
            isRefreshing: isRefreshing,
            hasColleagues: !colleagues.isEmpty
        )
        guard shouldRefresh, !isRefreshing, !colleagues.isEmpty else { return }
        refresh()
    }

    /// Unconditional refresh, wired to the popover's refresh button.
    func refresh() {
        guard !colleagues.isEmpty, let account = availabilityAccount, let calendarService else { return }
        refreshTask?.cancel()
        isRefreshing = true

        let emails = colleagues.map(\.email)
        let bounds = ColleagueAvailabilityWindow.bounds(now: clock(), calendar: calendar)

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await calendarService.userAvailability(
                    emails: emails,
                    from: bounds.start,
                    to: bounds.end,
                    accountID: account.id
                )
                // The response is matched to the request by position, so a mailbox Exchange
                // skipped would shift every row after it and print one colleague's calendar under
                // another's name. Nothing is worse for this feature than a confident wrong status,
                // so a short answer is treated as a failed refresh: the previous grid stays and
                // the header says the data is stale.
                guard rows.count == emails.count else {
                    self.applyMismatch(expected: emails.count, received: rows.count)
                    return
                }
                self.applySuccess(rows: rows, windowStart: bounds.start)
            } catch is CancellationError {
                self.isRefreshing = false
            } catch {
                self.applyFailure(error)
            }
        }
    }

    private func applySuccess(rows: [AttendeeAvailability], windowStart: Date) {
        availabilities = rows
        self.windowStart = windowStart
        lastSuccessAt = clock()
        lastAttemptFailed = false
        isRefreshing = false
        updateFreshness()
    }

    private func applyMismatch(expected: Int, received: Int) {
        log.error("Colleague availability rows do not match the request: expected \(expected, privacy: .public), got \(received, privacy: .public)")
        lastAttemptFailed = true
        isRefreshing = false
        updateFreshness()
    }

    private func applyFailure(_ error: Error) {
        // No addresses in the log: colleague mailboxes are exactly the kind of PII the diagnostic
        // log gate exists to keep out.
        log.error("Colleague availability refresh failed: \(String(describing: type(of: error)), privacy: .public)")
        lastAttemptFailed = true
        isRefreshing = false
        updateFreshness()
    }

    private func updateFreshness() {
        freshness = ColleagueRefreshPolicy.freshness(
            lastSuccessAt: lastSuccessAt,
            lastAttemptFailed: lastAttemptFailed,
            windowUsable: ColleagueRefreshPolicy.isWindowUsable(windowStart: windowStart, now: clock(), calendar: calendar)
        )
    }

    // MARK: - List editing

    func add(_ attendee: ResolvedAttendee) {
        colleagues = WatchedColleaguesStore.add(WatchedColleague(attendee: attendee, addedAt: clock()), store: store)
        refresh()
    }

    func update(_ colleague: WatchedColleague) {
        colleagues = WatchedColleaguesStore.update(colleague, store: store)
    }

    func remove(_ colleague: WatchedColleague) {
        colleagues = WatchedColleaguesStore.remove(id: colleague.id, store: store)
        if colleagues.isEmpty {
            availabilities = []
            windowStart = nil
            lastSuccessAt = nil
            lastAttemptFailed = false
            updateFreshness()
        }
    }

    func contains(_ attendee: ResolvedAttendee) -> Bool {
        colleagues.contains { $0.id == attendee.email.lowercased() }
    }

    // MARK: - Search

    func searchPeople(query: String) async throws -> [ResolvedAttendee] {
        guard let calendarService, let account = availabilityAccount else { return [] }
        return try await calendarService.findPeople(query: query, accountID: account.id)
    }
}
