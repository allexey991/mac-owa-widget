import Foundation

/// The parts of an HTTP request the feed server looks at.
struct ICSHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let host: String?
    let userAgent: String?
}

enum ICSHTTPParseResult: Equatable, Sendable {
    case complete(ICSHTTPRequest)
    /// The header block has not ended yet; read more.
    case incomplete
    /// Not an HTTP request at all — notably the TLS ClientHello Calendar.app sends before it
    /// falls back to plain http.
    case notHTTP
    case tooLarge
}

/// Minimal HTTP/1.x request-head parser: request line plus headers, no body (the feed serves
/// only GET and HEAD).
enum ICSHTTPRequestParser {
    static let maxBytes = 8 * 1024

    static func parse(_ data: Data) -> ICSHTTPParseResult {
        // A method is uppercase ASCII; anything else (0x16 for a TLS handshake) is decided on the
        // first byte instead of waiting out the read timeout.
        if let first = data.first, !(UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) {
            return .notHTTP
        }
        // ISO Latin-1 maps every byte, so decoding never fails on stray non-ASCII header bytes.
        guard let text = String(data: data.prefix(maxBytes + 4), encoding: .isoLatin1) else { return .notHTTP }

        guard let headEnd = text.range(of: "\r\n\r\n") else {
            if data.count > maxBytes { return .tooLarge }
            if let lineEnd = text.range(of: "\r\n"), parseRequestLine(String(text[..<lineEnd.lowerBound])) == nil {
                return .notHTTP
            }
            return .incomplete
        }
        if text.utf8.distance(from: text.startIndex, to: headEnd.lowerBound) > maxBytes { return .tooLarge }

        var lines = text[..<headEnd.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = parseRequestLine(lines.removeFirst()) else { return .notHTTP }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil { headers[name] = value }
        }
        return .complete(ICSHTTPRequest(
            method: requestLine.method,
            path: requestLine.path,
            host: headers["host"],
            userAgent: headers["user-agent"]
        ))
    }

    private static func parseRequestLine(_ line: String) -> (method: String, path: String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}
