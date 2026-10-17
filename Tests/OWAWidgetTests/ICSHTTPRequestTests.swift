import XCTest
@testable import OWAWidget

/// The feed server reads at most one small request per connection. Calendar.app's subscriber
/// opens with a TLS ClientHello before falling back to plain http, so "this is not HTTP" has to
/// be recognised from the first bytes rather than waited out.
final class ICSHTTPRequestTests: XCTestCase {
    private func parse(_ text: String) -> ICSHTTPParseResult {
        ICSHTTPRequestParser.parse(Data(text.utf8))
    }

    func testParsesGetWithHostAndUserAgent() {
        let result = parse(
            "GET /abc/calendar.ics HTTP/1.1\r\nHost: 127.0.0.1:47318\r\nUser-Agent: macOS/15.5 dataaccessd/1.0\r\nAccept: */*\r\n\r\n"
        )

        XCTAssertEqual(result, .complete(ICSHTTPRequest(
            method: "GET",
            path: "/abc/calendar.ics",
            host: "127.0.0.1:47318",
            userAgent: "macOS/15.5 dataaccessd/1.0"
        )))
    }

    func testHeaderNamesAreCaseInsensitive() {
        let result = parse("HEAD / HTTP/1.1\r\nhOST: localhost:1\r\n\r\n")

        guard case .complete(let request) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(request.method, "HEAD")
        XCTAssertEqual(request.host, "localhost:1")
        XCTAssertNil(request.userAgent)
    }

    func testMissingHostParsesWithNilHost() {
        guard case .complete(let request) = parse("GET / HTTP/1.0\r\n\r\n") else { return XCTFail() }

        XCTAssertNil(request.host)
    }

    func testHeadersWithoutBlankLineAreIncomplete() {
        XCTAssertEqual(parse("GET /abc HTTP/1.1\r\nHost: 127.0.0.1"), .incomplete)
        XCTAssertEqual(parse(""), .incomplete)
    }

    func testTLSClientHelloIsNotHTTP() {
        // Record type 0x16 (handshake), version 3.1 — what Calendar sends first.
        let hello = Data([0x16, 0x03, 0x01, 0x00, 0x7d, 0x01, 0x00, 0x00, 0x79, 0x03, 0x01])

        XCTAssertEqual(ICSHTTPRequestParser.parse(hello), .notHTTP)
    }

    func testGarbageRequestLineIsNotHTTP() {
        XCTAssertEqual(parse("HELLO\r\n\r\n"), .notHTTP)
        XCTAssertEqual(parse("GET /x SPDY/3\r\n\r\n"), .notHTTP)
    }

    func testOversizedRequestIsRejected() {
        let huge = "GET / HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: ICSHTTPRequestParser.maxBytes)

        XCTAssertEqual(parse(huge), .tooLarge)
    }
}
