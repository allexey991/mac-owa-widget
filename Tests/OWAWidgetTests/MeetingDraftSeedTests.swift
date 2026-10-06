import Combine
import XCTest
@testable import OWAWidget

/// A meeting from the MCP confirmation panel's Edit button, on its way into the New Meeting
/// window: the seed, the inbox that carries it and the form that takes it.
@MainActor
final class MeetingDraftSeedTests: XCTestCase {
    private let account = CalendarAccount(displayName: "Work", serverURL: "", email: "", accountType: .owa)
    private let ivanov = ResolvedAttendee(displayName: "Иванов Иван", email: "ivanov@corp.ru", jobTitle: nil)
    private let petrov = ResolvedAttendee(displayName: "Петров Пётр", email: "petrov@corp.ru", jobTitle: nil)

    /// Next week's Tuesday at 15:00 in the display time zone: always in the future, always on a
    /// weekday the grid shows.
    private var nextTuesday: Date {
        let calendar = MeetingDraft.weekCalendar
        let monday = MeetingDraft.mondayOfWeek(containing: Date()).addingTimeInterval(7 * 86400)
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        return calendar.date(bySettingHour: 15, minute: 0, second: 0, of: tuesday)!
    }

    private func seed(minutes: Int = 45, title: String = "Релиз", accountID: UUID? = nil) -> MeetingDraftSeed {
        MeetingDraftSeed(
            title: title,
            agenda: "План",
            location: "",
            required: [ivanov],
            optional: [petrov],
            slot: DateInterval(start: nextTuesday, duration: TimeInterval(minutes * 60)),
            accountID: accountID ?? account.id,
            client: "Claude Code"
        )
    }

    private func makeViewModel() -> CreateMeetingViewModel {
        let service = CalendarService(
            providers: [],
            notificationService: SilentNotificationService(),
            customMeetingReminders: SilentMeetingReminderController(),
            loadPersistedAccounts: false,
            startBackgroundTasks: false
        )
        return CreateMeetingViewModel(calendarService: service, accountID: account.id)
    }

    // MARK: - Seed

    func testSeedFromProposalKeepsNamesAndFallsBackToAddresses() {
        let proposal = MCPMeetingProposal(
            title: "t", start: nextTuesday, end: nextTuesday.addingTimeInterval(1800),
            required: [.init(email: "ivanov@corp.ru", name: "Иванов Иван", isExternal: false)],
            optional: [.init(email: "guest@partner.com", name: nil, isExternal: true)],
            location: "Room 1", agenda: "a", conflicts: [], client: "Claude Code", externalCheckAvailable: true
        )

        let seed = MeetingDraftSeed(proposal: proposal, accountID: account.id)

        XCTAssertEqual(seed.required.map(\.displayName), ["Иванов Иван"])
        XCTAssertEqual(seed.optional.map(\.displayName), ["guest@partner.com"])
        XCTAssertEqual(seed.slot, DateInterval(start: nextTuesday, end: nextTuesday.addingTimeInterval(1800)))
        XCTAssertEqual(seed.location, "Room 1")
        XCTAssertEqual(seed.accountID, account.id)
    }

    func testDurationChipIsTheShortestPresetTheMeetingFits() {
        XCTAssertEqual(seed(minutes: 15).durationMinutes, 30)
        XCTAssertEqual(seed(minutes: 30).durationMinutes, 30)
        XCTAssertEqual(seed(minutes: 45).durationMinutes, 60)
        XCTAssertEqual(seed(minutes: 120).durationMinutes, 120)
        XCTAssertEqual(seed(minutes: 150).durationMinutes, 150)
    }

    func testDraftOpensOnTheWeekOfTheProposedTime() {
        let draft = seed().makeDraft()

        XCTAssertEqual(draft.selectedWeekStart, MeetingDraft.mondayOfWeek(containing: nextTuesday))
        XCTAssertEqual(draft.title, "Релиз")
        XCTAssertEqual(draft.requiredAttendees, [ivanov])
        XCTAssertEqual(draft.optionalAttendees, [petrov])
        XCTAssertEqual(draft.durationMinutes, 60)
    }

    // MARK: - Inbox

    func testInboxDropsADraftNobodyTookInTime() {
        var now = Date()
        let inbox = MeetingDraftInbox(clock: { now })
        inbox.hold(seed())
        XCTAssertNotNil(inbox.fresh)

        now = now.addingTimeInterval(MeetingDraftInbox.maxAge + 1)

        XCTAssertNil(inbox.fresh)
        XCTAssertNil(inbox.take())
        XCTAssertNil(inbox.pending)
    }

    func testInboxGivesADraftOnlyOnce() {
        let inbox = MeetingDraftInbox()
        let sent = seed()
        inbox.hold(sent)

        XCTAssertEqual(inbox.take(), sent)
        XCTAssertNil(inbox.take())
    }

    func testTakingFromAnEmptyInboxAnnouncesNothing() {
        // The window takes from the inbox on every announcement: an announcement from an empty
        // take would make it take again, forever, on the main thread.
        let inbox = MeetingDraftInbox()
        var announcements = 0
        let subscription = inbox.$pending.dropFirst().sink { _ in announcements += 1 }

        XCTAssertNil(inbox.take())
        XCTAssertNil(inbox.take())
        inbox.hold(seed())
        _ = inbox.take()
        _ = inbox.take()

        XCTAssertEqual(announcements, 2)
        subscription.cancel()
    }

    // MARK: - Form

    func testEmptyFormTakesTheDraftAtOnce() {
        let vm = makeViewModel()
        let sent = seed()

        vm.receive(sent)

        XCTAssertNil(vm.offeredSeed)
        XCTAssertEqual(vm.draft.title, "Релиз")
        XCTAssertEqual(vm.draft.requiredAttendees, [ivanov])
        XCTAssertEqual(vm.seedClient, "Claude Code")
        XCTAssertEqual(vm.selectedSlot?.start, sent.slot.start)
        XCTAssertEqual(vm.selectedSlot?.end, sent.slot.end)
    }

    func testFormWithTheUsersWorkOffersTheDraftInsteadOfOverwriting() {
        let vm = makeViewModel()
        vm.draft.title = "Моя встреча"
        let sent = seed()

        vm.receive(sent)

        XCTAssertEqual(vm.offeredSeed, sent)
        XCTAssertEqual(vm.draft.title, "Моя встреча")

        vm.apply(sent)
        XCTAssertNil(vm.offeredSeed)
        XCTAssertEqual(vm.draft.title, "Релиз")
    }

    func testKeepingTheUsersDraftDropsTheOffer() {
        let vm = makeViewModel()
        vm.draft.agenda = "черновик"
        vm.receive(seed())

        vm.dismissOfferedSeed()

        XCTAssertNil(vm.offeredSeed)
        XCTAssertEqual(vm.draft.agenda, "черновик")
        XCTAssertNil(vm.seedClient)
    }

    func testProposedTimeSurvivesTheSlotReload() async {
        let vm = makeViewModel()
        let sent = seed()
        vm.apply(sent)

        await vm.findSlots()

        XCTAssertEqual(vm.selectedSlot?.start, sent.slot.start)
        XCTAssertEqual(vm.selectedSlot?.end, sent.slot.end)
    }

    func testTheUsersOwnChoiceIsNotOverriddenByTheProposedTime() async {
        let vm = makeViewModel()
        let sent = seed()
        vm.apply(sent)
        let own = sent.slot.start.addingTimeInterval(3600)

        vm.selectSlot(start: own, end: own.addingTimeInterval(1800))
        await vm.findSlots()

        XCTAssertNotEqual(vm.selectedSlot?.start, sent.slot.start)
    }

    func testDraftAttendeesDoNotBecomeFrequentContacts() {
        let vm = makeViewModel()
        let before = RecentAttendeesStore.load().map(\.attendee.email)

        vm.apply(seed())

        XCTAssertEqual(RecentAttendeesStore.load().map(\.attendee.email), before)
    }

    func testResetForgetsTheDraftsOrigin() {
        let vm = makeViewModel()
        vm.apply(seed())

        vm.reset()

        XCTAssertNil(vm.seedClient)
        XCTAssertNil(vm.offeredSeed)
        XCTAssertTrue(vm.canReplaceDraftSilently)
    }
}
