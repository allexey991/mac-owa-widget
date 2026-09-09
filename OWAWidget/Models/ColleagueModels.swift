import Foundation

/// A colleague the user keeps an eye on in the popover, plus the optional link to their
/// permanent personal meeting room.
///
/// Identity is the mailbox address, lowercased: the address book can spell the same person
/// differently between a search hit and a meeting attendee, and two entries for one mailbox would
/// mean two rows and two availability rows for the same human.
struct WatchedColleague: Identifiable, Codable, Sendable, Hashable {
    var displayName: String
    var email: String
    var jobTitle: String?
    /// Permanent personal room (Teams, Zoom, Webex, …). `nil` means the row shows no join button:
    /// there is nothing to join, and a dead button is worse than no button.
    var roomURL: String?
    var addedAt: Date

    var id: String { email.lowercased() }

    init(displayName: String, email: String, jobTitle: String? = nil, roomURL: String? = nil, addedAt: Date = Date()) {
        self.displayName = displayName
        self.email = email
        self.jobTitle = jobTitle
        self.roomURL = roomURL
        self.addedAt = addedAt
    }

    init(attendee: ResolvedAttendee, roomURL: String? = nil, addedAt: Date = Date()) {
        self.init(
            displayName: attendee.displayName,
            email: attendee.email,
            jobTitle: attendee.jobTitle,
            roomURL: roomURL,
            addedAt: addedAt
        )
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Current free/busy state of a colleague as far as the downloaded grid knows.
///
/// `noData` is deliberately its own case rather than folded into `free`. Exchange writes `4` into
/// the merged string for a mailbox whose free/busy this user may not read, and treating that as
/// "free" would invite a call to someone whose calendar we cannot see at all.
enum ColleaguePresence: String, Sendable, Equatable {
    case free
    case tentative
    case busy
    case away
    case noData

    init(freeBusyCode: Character) {
        switch freeBusyCode {
        case "0": self = .free
        case "1": self = .tentative
        case "2": self = .busy
        case "3": self = .away
        default: self = .noData
        }
    }

    /// Free first, unknown last — the order the section sorts rows in.
    var sortRank: Int {
        switch self {
        case .free: 0
        case .tentative: 1
        case .busy: 2
        case .away: 3
        case .noData: 4
        }
    }

    var localizationKey: String {
        switch self {
        case .free: "colleagues.status.free"
        case .tentative: "colleagues.status.tentative"
        case .busy: "colleagues.status.busy"
        case .away: "colleagues.status.away"
        case .noData: "colleagues.status.unknown"
        }
    }
}

/// A colleague's state at one moment, plus when that state is known to end.
struct ColleagueStatus: Sendable, Equatable {
    let presence: ColleaguePresence
    /// First instant the state changes. `nil` when the downloaded window ends before the state
    /// does, so the UI says "Занят" without promising an hour it cannot know.
    let until: Date?

    static let unknown = ColleagueStatus(presence: .noData, until: nil)
}

/// How much the section can vouch for what it shows.
enum ColleagueDataFreshness: Sendable, Equatable {
    /// Refreshed successfully; statuses are rendered plainly.
    case fresh
    /// The last refresh failed. The day's grid is still on hand, so statuses stay on screen with a
    /// hollow dot: what could have changed is the grid, not the passage of time.
    case stale(since: Date)
    /// Nothing usable: never fetched, or the grid on hand is from another day.
    case none
}
