import Foundation

/// Exchange's meeting identity (MS-OXOCAL `PidLidGlobalObjectId`), which OWA returns as hex in
/// `UID` (`GetCalendarEvent`) and `SeriesId` (`GetCalendarView`). The same for every copy of the
/// meeting in every mailbox, unlike `ItemId`.
///
/// Layout: 16 bytes class id, 4 bytes occurrence date (zero for the series as a whole), 8 bytes
/// creation time, 8 reserved, 4 bytes little-endian data size, then the data. A meeting that came
/// from another calendar system carries its original iCalendar UID in the data, after the
/// `vCal-Uid` marker.
enum ExchangeGlobalObjectID {
    private static let classID: [UInt8] = [
        0x04, 0x00, 0x00, 0x00, 0x82, 0x00, 0xE0, 0x00,
        0x74, 0xC5, 0xB7, 0x10, 0x1A, 0x82, 0xE0, 0x08,
    ]
    private static let headerLength = 40
    private static let vCalMarker = Array("vCal-Uid".utf8) + [0x01, 0x00, 0x00, 0x00]

    /// The iCalendar UID of the meeting — of the whole series for a recurring one: the original
    /// UID for a meeting from another calendar system, otherwise the Global Object ID with the
    /// occurrence date cleared, as Exchange itself writes it into iCalendar. A value that is not
    /// a Global Object ID is returned as is.
    static func icalUID(fromHex hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var bytes = bytes(fromHex: trimmed),
              bytes.count >= headerLength,
              Array(bytes.prefix(classID.count)) == classID
        else { return trimmed }

        let size = Int(bytes[36]) | Int(bytes[37]) << 8 | Int(bytes[38]) << 16 | Int(bytes[39]) << 24
        let data = Array(bytes.dropFirst(headerLength).prefix(size))
        if data.count > vCalMarker.count, Array(data.prefix(vCalMarker.count)) == vCalMarker {
            let uidBytes = data.dropFirst(vCalMarker.count).prefix { $0 != 0 }
            if let uid = String(bytes: uidBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !uid.isEmpty {
                return uid
            }
        }

        bytes.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
