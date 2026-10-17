import Foundation
import Security

/// Persisted settings of the ICS feed. The switch and the port are interface settings and live in
/// `UserDefaults`; the token is a secret (it is what keeps other local processes out of the
/// feed) and goes through `SecureStore`.
final class ICSFeedSettings: @unchecked Sendable {
    static let enabledKey = "icsFeedEnabled"
    static let portKey = "icsFeedPort"
    static let defaultPort: UInt16 = 47318

    private let defaults: UserDefaults
    private let tokenStore: SecureCodableStore<String>
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, secureStore: SecureStore = .shared) {
        self.defaults = defaults
        // The token can always be regenerated (at the cost of re-subscribing), so an unreadable
        // container is treated as empty rather than blocking the feature.
        self.tokenStore = SecureCodableStore(
            name: "ics-feed-token",
            legacyKey: nil,
            store: secureStore,
            defaults: defaults,
            policy: .treatAsEmpty
        )
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var port: UInt16 {
        get {
            let stored = defaults.integer(forKey: Self.portKey)
            return (1...Int(UInt16.max)).contains(stored) ? UInt16(stored) : Self.defaultPort
        }
        set { defaults.set(Int(newValue), forKey: Self.portKey) }
    }

    /// The current token, created on first use.
    func token() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let stored = tokenStore.load(), !stored.isEmpty { return stored }
        let token = Self.makeToken()
        _ = tokenStore.save(token)
        return token
    }

    /// Issues a new token; the old subscription URL stops working.
    @discardableResult
    func regenerateToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        let token = Self.makeToken()
        _ = tokenStore.save(token)
        return token
    }

    /// Accounts whose meetings the feed serves: Exchange only. EventKit calendars are already in
    /// Calendar.app, and serving them again would duplicate every event.
    static func feedAccountIDs(_ accounts: [CalendarAccount]) -> Set<UUID> {
        Set(accounts.filter { $0.accountType == .owa }.map(\.id))
    }

    /// 128 random bits as lowercase hex.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Practically unreachable; SystemRandomNumberGenerator is also a CSPRNG on macOS.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
