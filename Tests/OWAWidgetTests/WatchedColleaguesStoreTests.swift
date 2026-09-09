import XCTest
@testable import OWAWidget

/// The watched list holds names, addresses and job titles from the corporate address book, so it
/// lives in the encrypted store. Tests inject their own container and key: touching the real
/// Keychain would hang `make release-package` behind an authorisation prompt.
final class WatchedColleaguesStoreTests: XCTestCase {
    private var directory: URL!
    private var secureStore: SecureStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("watched-colleagues-tests-\(UUID().uuidString)", isDirectory: true)
        secureStore = SecureStore(directory: directory, keyProvider: InMemorySecureStoreKeyProvider())
        suiteName = "watchedcolleagues.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeStore() -> WatchedColleaguesStore.Store {
        WatchedColleaguesStore.makeStore(secureStore: secureStore, defaults: defaults)
    }

    private func colleague(_ email: String, name: String = "Анна Ковалёва", room: String? = nil, addedAt: Date = Date()) -> WatchedColleague {
        WatchedColleague(displayName: name, email: email, jobTitle: "Дизайнер", roomURL: room, addedAt: addedAt)
    }

    func testAddedColleagueSurvivesAReload() {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("anna@example.com", room: "https://example.com/room"), store: store)

        let reloaded = WatchedColleaguesStore.load(store: makeStore())

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.roomURL, "https://example.com/room")
    }

    /// The same mailbox spelled differently is the same person, not a second row and a second
    /// availability entry.
    func testAddingTheSameMailboxAgainUpdatesInsteadOfDuplicating() {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("Anna@Example.com", room: "https://example.com/room"), store: store)

        let list = WatchedColleaguesStore.add(colleague("anna@example.com", name: "Анна К."), store: store)

        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.displayName, "Анна К.")
        XCTAssertEqual(list.first?.roomURL, "https://example.com/room", "Re-adding must not wipe the link the user typed")
    }

    func testUpdateStoresTheRoomLinkAndRemoveDropsThePerson() {
        let store = makeStore()
        var added = WatchedColleaguesStore.add(colleague("dmitry@example.com"), store: store).first!
        added.roomURL = "https://teams.microsoft.com/l/meetup-join/abc"

        let updated = WatchedColleaguesStore.update(added, store: store)
        XCTAssertEqual(updated.first?.roomURL, "https://teams.microsoft.com/l/meetup-join/abc")

        let remaining = WatchedColleaguesStore.remove(id: "DMITRY@example.com", store: store)
        XCTAssertTrue(remaining.isEmpty)
    }

    /// The stored array is the order the section shows, so new people land at the end.
    func testNewColleaguesAreAppended() {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("first@example.com"), store: store)
        _ = WatchedColleaguesStore.add(colleague("second@example.com"), store: store)

        XCTAssertEqual(WatchedColleaguesStore.load(store: store).map(\.email), ["first@example.com", "second@example.com"])
    }

    func testMovingAColleagueSwapsNeighboursAndPersists() {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("first@example.com"), store: store)
        _ = WatchedColleaguesStore.add(colleague("second@example.com"), store: store)

        let moved = WatchedColleaguesStore.move(id: "second@example.com", offset: -1, store: store)
        XCTAssertEqual(moved.map(\.email), ["second@example.com", "first@example.com"])
        XCTAssertEqual(WatchedColleaguesStore.load(store: makeStore()).map(\.email), ["second@example.com", "first@example.com"])
    }

    func testMovingPastTheEdgesIsANoOp() {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("first@example.com"), store: store)
        _ = WatchedColleaguesStore.add(colleague("second@example.com"), store: store)

        XCTAssertEqual(WatchedColleaguesStore.move(id: "first@example.com", offset: -1, store: store).map(\.email),
                       ["first@example.com", "second@example.com"])
        XCTAssertEqual(WatchedColleaguesStore.move(id: "second@example.com", offset: 1, store: store).map(\.email),
                       ["first@example.com", "second@example.com"])
        XCTAssertEqual(WatchedColleaguesStore.move(id: "nobody@example.com", offset: 1, store: store).count, 2)
    }

    /// A drag drops one person onto another's row: the dragged colleague takes that slot, in
    /// both directions, and the rest close ranks.
    func testDropMovesTheColleagueIntoTheTargetSlot() {
        let store = makeStore()
        for email in ["a@example.com", "b@example.com", "c@example.com"] {
            _ = WatchedColleaguesStore.add(colleague(email), store: store)
        }

        let draggedDown = WatchedColleaguesStore.move(id: "a@example.com", toIndex: 2, store: store)
        XCTAssertEqual(draggedDown.map(\.email), ["b@example.com", "c@example.com", "a@example.com"])

        let draggedUp = WatchedColleaguesStore.move(id: "a@example.com", toIndex: 0, store: store)
        XCTAssertEqual(draggedUp.map(\.email), ["a@example.com", "b@example.com", "c@example.com"])
    }

    func testDropOutsideTheListIsClamped() {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("a@example.com"), store: store)
        _ = WatchedColleaguesStore.add(colleague("b@example.com"), store: store)

        XCTAssertEqual(WatchedColleaguesStore.move(id: "a@example.com", toIndex: 99, store: store).map(\.email),
                       ["b@example.com", "a@example.com"])
        XCTAssertEqual(WatchedColleaguesStore.move(id: "unknown@example.com", toIndex: 0, store: store).count, 2)
    }

    func testNothingIsWrittenInCleartext() throws {
        let store = makeStore()
        _ = WatchedColleaguesStore.add(colleague("anna@example.com"), store: store)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "anna@example.com"))
        }
    }
}
