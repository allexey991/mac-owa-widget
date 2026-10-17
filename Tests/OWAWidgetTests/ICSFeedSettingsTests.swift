import XCTest
@testable import OWAWidget

/// The feed's persisted settings. The token is part of the subscription URL the user pasted into
/// Calendar.app, so it must survive relaunches and change only on an explicit "new address".
final class ICSFeedSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private let keyProvider = InMemorySecureStoreKeyProvider()

    override func setUp() {
        super.setUp()
        suiteName = "com.owawidget.tests.icsfeed.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("icsfeed-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeSettings() -> ICSFeedSettings {
        ICSFeedSettings(defaults: defaults, secureStore: SecureStore(directory: directory, keyProvider: keyProvider))
    }

    func testFeatureIsOffByDefault() {
        XCTAssertFalse(makeSettings().isEnabled)
    }

    func testDefaultPort() {
        XCTAssertEqual(makeSettings().port, 47318)
    }

    func testPortPersists() {
        let settings = makeSettings()
        settings.port = 50000

        XCTAssertEqual(makeSettings().port, 50000)
    }

    func testTokenIs128BitHex() {
        let token = makeSettings().token()

        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testTokenSurvivesRelaunch() {
        let first = makeSettings().token()

        XCTAssertEqual(makeSettings().token(), first)
    }

    func testTokenIsNotKeptInUserDefaults() {
        let token = makeSettings().token()

        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(stored.contains(token))
    }

    func testRegenerateReplacesAndPersistsToken() {
        let settings = makeSettings()
        let old = settings.token()

        let new = settings.regenerateToken()

        XCTAssertNotEqual(new, old)
        XCTAssertEqual(makeSettings().token(), new)
    }

    func testOnlyExchangeAccountsFeedTheCalendar() {
        let owa = CalendarAccount(displayName: "Work", serverURL: "https://mail.example", email: "a@example.com", accountType: .owa)
        let eventKit = CalendarAccount(displayName: "iCloud", serverURL: "", email: "", accountType: .eventKit)

        XCTAssertEqual(ICSFeedSettings.feedAccountIDs([owa, eventKit]), [owa.id])
    }
}
