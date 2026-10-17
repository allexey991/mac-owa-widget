import XCTest

/// A missing key shows up in the UI as the raw key ("icsFeed.status.waiting"), so every key the
/// feed's code asks for must exist in both languages.
final class ICSFeedLocalizationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func strings(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("OWAWidget/Resources/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(language) strings unreadable")
    }

    /// Keys referenced as `tr("icsFeed…")`/`tr("settings.tab.icsFeed")` in the sources, plus the
    /// numbered subscription steps the view builds in a loop.
    private func referencedKeys() throws -> Set<String> {
        let files = ["OWAWidget/Views/ICSFeedSettingsView.swift", "OWAWidget/ICSFeed/ICSFeedService.swift", "OWAWidget/Views/SettingsView.swift"]
        let regex = try NSRegularExpression(pattern: #"tr\("((?:icsFeed|settings\.tab\.icsFeed)[A-Za-z0-9.]*)""#)
        var keys: Set<String> = []
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        keys.remove("icsFeed.subscribe.step")
        (1...4).forEach { keys.insert("icsFeed.subscribe.step\($0)") }
        return keys
    }

    func testEveryReferencedKeyExistsInBothLanguages() throws {
        let keys = try referencedKeys()
        XCTAssertGreaterThan(keys.count, 20, "regex found too few keys: \(keys)")

        for language in ["en", "ru"] {
            let table = try strings(language)
            let missing = keys.filter { table[$0] == nil }.sorted()
            XCTAssertEqual(missing, [], "missing in \(language)")
        }
    }

    func testFeedKeySetsMatchBetweenLanguages() throws {
        let en = Set(try strings("en").keys.filter { $0.hasPrefix("icsFeed.") })
        let ru = Set(try strings("ru").keys.filter { $0.hasPrefix("icsFeed.") })

        XCTAssertEqual(en.symmetricDifference(ru).sorted(), [])
    }
}
