import Foundation

/// The colleagues whose availability the popover watches.
///
/// Names, addresses, job titles and room links come from the corporate address book and from the
/// user, so the list is encrypted at rest like every other store here rather than sitting in
/// `UserDefaults`. There is no legacy plist key: the feature ships straight into `SecureStore`.
enum WatchedColleaguesStore {
    typealias Store = SecureCodableStore<[WatchedColleague]>

    static let storageName = "watchedColleagues"
    /// Every colleague costs characters in one availability response, not a request of their own,
    /// so the cap is about a readable list rather than about load.
    static let maxCount = 30

    static let shared: Store = makeStore()

    static func makeStore(
        secureStore: SecureStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Store {
        Store(
            name: storageName,
            legacyKey: nil,
            store: secureStore,
            defaults: defaults,
            policy: .fallBackToLegacy
        )
    }

    static func load(store: Store = shared) -> [WatchedColleague] {
        sorted(store.load() ?? [])
    }

    static func save(_ colleagues: [WatchedColleague], store: Store = shared) {
        store.save(Array(sorted(colleagues).prefix(maxCount)))
    }

    /// Adds a colleague, or refreshes the address-book fields of one already on the list without
    /// dropping the room link the user typed in.
    static func add(_ colleague: WatchedColleague, store: Store = shared) -> [WatchedColleague] {
        var current = load(store: store)
        if let index = current.firstIndex(where: { $0.id == colleague.id }) {
            current[index].displayName = colleague.displayName
            current[index].jobTitle = colleague.jobTitle
            if let room = colleague.roomURL, !room.isEmpty {
                current[index].roomURL = room
            }
        } else {
            current.append(colleague)
        }
        save(current, store: store)
        return load(store: store)
    }

    static func update(_ colleague: WatchedColleague, store: Store = shared) -> [WatchedColleague] {
        var current = load(store: store)
        guard let index = current.firstIndex(where: { $0.id == colleague.id }) else {
            return add(colleague, store: store)
        }
        current[index] = colleague
        save(current, store: store)
        return load(store: store)
    }

    static func remove(id: String, store: Store = shared) -> [WatchedColleague] {
        let current = load(store: store).filter { $0.id != id.lowercased() }
        save(current, store: store)
        return load(store: store)
    }

    /// Oldest first: the list is the user's own ordering by the time they added people, and a
    /// row that jumps around between openings is hard to aim at.
    private static func sorted(_ colleagues: [WatchedColleague]) -> [WatchedColleague] {
        colleagues.sorted { $0.addedAt < $1.addedAt }
    }
}
