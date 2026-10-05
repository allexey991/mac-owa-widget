import Foundation

/// Matches `GetUserAvailabilityInternal` free/busy strings to the requested addresses.
///
/// Exchange answers with one response per mailbox, in request order, and a mailbox it has no
/// data for (outside the organization, no permission, unknown) gets a response without
/// `MergedFreeBusy`. Collecting every `MergedFreeBusy` in the document and zipping them with the
/// addresses, as this code used to, shifted every row after such a mailbox onto the next person:
/// one colleague's calendar under another's name.
///
/// So the strings are read per response: the array of responses is the array with one element per
/// requested address that carries `MergedFreeBusy` somewhere inside. A mailbox without a string is
/// left out. When no such array is found the old reading is used only if it is unambiguous (as
/// many strings as addresses); otherwise nothing is returned rather than a guess.
enum OWAAvailabilityResponseParser {
    static func parse(_ json: Any, emails: [String], windowStart: Date) -> [AttendeeAvailability] {
        func row(_ email: String, _ merged: String) -> AttendeeAvailability {
            AttendeeAvailability(email: email, mergedFreeBusy: merged, windowStart: windowStart, intervalMinutes: 30)
        }
        guard !emails.isEmpty else { return [] }

        if let responses = responseArray(in: json, count: emails.count) {
            return zip(emails, responses).compactMap { email, response in
                firstMergedFreeBusy(in: response).map { row(email, $0) }
            }
        }
        var all: [String] = []
        collectMergedFreeBusy(in: json, into: &all)
        guard all.count == emails.count else { return [] }
        return zip(emails, all).map(row)
    }

    /// The first array, depth first, with `count` object elements of which at least one holds a
    /// non-empty `MergedFreeBusy` and none holds two.
    private static func responseArray(in value: Any, count: Int) -> [Any]? {
        if let array = value as? [Any] {
            if array.count == count, array.allSatisfy({ $0 is [String: Any] }) {
                let counts = array.map { element -> Int in
                    var found: [String] = []
                    collectMergedFreeBusy(in: element, into: &found)
                    return found.count
                }
                if counts.contains(where: { $0 > 0 }), counts.allSatisfy({ $0 <= 1 }) {
                    return array
                }
            }
            for item in array {
                if let found = responseArray(in: item, count: count) { return found }
            }
        } else if let dict = value as? [String: Any] {
            // Sorted keys: the walk must not depend on dictionary order.
            for key in dict.keys.sorted() {
                if let found = responseArray(in: dict[key] as Any, count: count) { return found }
            }
        }
        return nil
    }

    private static func firstMergedFreeBusy(in value: Any) -> String? {
        var found: [String] = []
        collectMergedFreeBusy(in: value, into: &found)
        return found.first
    }

    private static func collectMergedFreeBusy(in value: Any, into results: inout [String]) {
        if let dict = value as? [String: Any] {
            if let merged = dict["MergedFreeBusy"] as? String, !merged.isEmpty {
                results.append(merged)
                return
            }
            for key in dict.keys.sorted() {
                collectMergedFreeBusy(in: dict[key] as Any, into: &results)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectMergedFreeBusy(in: item, into: &results)
            }
        }
    }
}
