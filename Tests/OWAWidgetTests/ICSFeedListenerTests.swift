import Network
import XCTest
@testable import OWAWidget

/// The listener over a real loopback socket: what Calendar.app's `dataaccessd` will talk to.
final class ICSFeedListenerTests: XCTestCase {
    private var listeners: [ICSFeedListener] = []

    override func tearDown() {
        listeners.forEach { $0.stop() }
        listeners = []
    }

    private static let okResponse = ICSHTTPResponse(
        status: 200,
        reason: "OK",
        headers: ["Content-Type": "text/calendar; charset=utf-8"],
        body: Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)
    )

    /// Starts a listener and waits for its first state.
    private func start(port: UInt16 = 0) throws -> (ICSFeedListener, ICSFeedListener.State) {
        let ready = expectation(description: "state")
        let box = StateBox()
        let listener = ICSFeedListener(port: port, respond: { _ in Self.okResponse }) { state in
            if box.set(state) { ready.fulfill() }
        }
        listeners.append(listener)
        try listener.start()
        wait(for: [ready], timeout: 5)
        return (listener, box.first!)
    }

    func testServesGetOverLoopback() async throws {
        let (_, state) = try start()
        guard case .ready(let port) = state else { return XCTFail("\(state)") }

        let url = URL(string: "http://127.0.0.1:\(port)/token/calendar.ics")!
        let (data, response) = try await URLSession.shared.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
    }

    func testTLSClientHelloGetsBadRequestAndListenerKeepsServing() async throws {
        let (_, state) = try start()
        guard case .ready(let port) = state else { return XCTFail("\(state)") }

        let reply = try await rawExchange(port: port, bytes: Data([0x16, 0x03, 0x01, 0x00, 0x7d, 0x01, 0x00]))
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 400 "))

        // Calendar.app falls back to plain http on the next connection.
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/x")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testSecondListenerOnSamePortReportsPortInUse() throws {
        let (_, state) = try start()
        guard case .ready(let port) = state else { return XCTFail("\(state)") }

        let (_, second) = try start(port: port)

        XCTAssertEqual(second, .portInUse)
    }

    // MARK: - Helpers

    private func rawExchange(port: UInt16, bytes: Data) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .global())
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { return continuation.resume(throwing: error) }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error { return continuation.resume(throwing: error) }
                    continuation.resume(returning: data ?? Data())
                }
            })
        }
    }
}

/// Keeps the first state a listener reports; later ones (e.g. cancellation) are ignored.
private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var first: ICSFeedListener.State?

    func set(_ state: ICSFeedListener.State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard first == nil else { return false }
        first = state
        return true
    }
}
