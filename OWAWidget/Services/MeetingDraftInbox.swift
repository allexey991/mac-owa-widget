import Combine
import Foundation

/// Hands a `MeetingDraftSeed` from the MCP confirmation panel to the New Meeting window. The
/// window is a SwiftUI scene that only a view can open, so the seed waits here while
/// `.openCreateMeetingShortcut` asks the menu bar label to open it; the window takes it on
/// appear, or right away when it is already open.
@MainActor
final class MeetingDraftInbox: ObservableObject {
    static let shared = MeetingDraftInbox()

    /// A seed nobody took within this time is dropped: the window failed to open, and the draft
    /// must not pop up later when the user opens the window for something else.
    static let maxAge: TimeInterval = 60

    @Published private(set) var pending: MeetingDraftSeed?
    private var deliveredAt: Date?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Stores the seed and opens the New Meeting window.
    func deliver(_ seed: MeetingDraftSeed) {
        hold(seed)
        MCPDebugLog.log("draft inbox: deliver \(seed.id) account=\(seed.accountID)")
        NotificationCenter.default.post(name: .openCreateMeetingShortcut, object: nil)
    }

    /// Stores the seed without opening anything: the window that will take it is already being
    /// rebuilt for the seed's account.
    func hold(_ seed: MeetingDraftSeed) {
        pending = seed
        deliveredAt = clock()
    }

    /// The waiting seed, if it is still fresh. Does not remove it.
    var fresh: MeetingDraftSeed? {
        guard let pending, let deliveredAt else { return nil }
        guard clock().timeIntervalSince(deliveredAt) <= Self.maxAge else { return nil }
        return pending
    }

    /// Removes and returns the waiting seed; a stale one is dropped and `nil` returned.
    func take() -> MeetingDraftSeed? {
        // Never writes to an empty inbox: `@Published` announces every write, and the window
        // takes from the inbox whenever it announces one — a write here would loop forever.
        guard let waiting = pending else { return nil }
        let seed = fresh
        MCPDebugLog.log("draft inbox: take \(waiting.id) fresh=\(seed != nil)")
        pending = nil
        deliveredAt = nil
        return seed
    }
}
