import XCTest
@testable import OWAWidget

final class MCPProtocolHandlerTests: XCTestCase {
    private let handler = MCPProtocolHandler(
        serverName: "owa-widget",
        serverTitle: "OWA Widget",
        serverVersion: "1.0.0",
        instructions: "Read-only calendar.",
        tools: [
            MCPToolDefinition(name: "b_tool", title: "B", description: "b", inputSchema: ["type": "object"]),
            MCPToolDefinition(name: "a_tool", title: "A", description: "a", inputSchema: ["type": "object"]),
        ]
    )

    private let modernMeta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    private func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]
    }

    private func reply(_ dispatch: MCPDispatch, file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        guard case .reply(let value) = dispatch else {
            XCTFail("expected a reply, got \(dispatch)", file: file, line: line)
            return .null
        }
        return value
    }

    // MARK: - Legacy

    func testInitializeEchoesSupportedLegacyVersion() {
        var session = MCPSessionState()
        let response = reply(handler.handle(request(1, "initialize", ["protocolVersion": "2025-06-18"]), session: &session))

        XCTAssertEqual(response["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(response["result"]?["instructions"], "Read-only calendar.")
        XCTAssertEqual(session.era, .legacy(version: "2025-06-18"))
    }

    func testInitializeWithUnknownVersionGetsNewestLegacyNeverModern() {
        var session = MCPSessionState()
        for requested in ["2024-11-05", "2026-07-28", "garbage"] {
            let response = reply(handler.handle(request(1, "initialize", ["protocolVersion": .string(requested)]), session: &session))
            XCTAssertEqual(response["result"]?["protocolVersion"], "2025-11-25", requested)
        }
    }

    func testLegacyToolsListHasNoModernFields() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let result = reply(handler.handle(request(2, "tools/list"), session: &session))["result"]

        XCTAssertEqual(result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["b_tool", "a_tool"])
        XCTAssertNil(result?["resultType"])
        XCTAssertNil(result?["ttlMs"])
        XCTAssertEqual(result?["tools"]?.arrayValue?.first?["annotations"]?["readOnlyHint"], true)
    }

    func testPingAndInitializedNotification() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        XCTAssertEqual(reply(handler.handle(request(3, "ping"), session: &session))["result"], [:])
        XCTAssertEqual(handler.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], session: &session), MCPDispatch.none)
    }

    // MARK: - Modern

    func testDiscoverCarriesEveryRequiredField() {
        var session = MCPSessionState()
        let result = reply(handler.handle(request(1, "server/discover", ["_meta": modernMeta]), session: &session))["result"]

        XCTAssertEqual(result?["resultType"], "complete")
        XCTAssertEqual(result?["supportedVersions"], ["2026-07-28"])
        XCTAssertNotNil(result?["capabilities"]?["tools"])
        XCTAssertEqual(result?["instructions"], "Read-only calendar.")
        XCTAssertNotNil(result?["ttlMs"])
        XCTAssertEqual(result?["cacheScope"], "private")
        XCTAssertEqual(result?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], "owa-widget")
    }

    func testModernToolsListIsCacheable() {
        var session = MCPSessionState()
        let result = reply(handler.handle(request(2, "tools/list", ["_meta": modernMeta]), session: &session))["result"]

        XCTAssertEqual(result?["resultType"], "complete")
        XCTAssertEqual(result?["ttlMs"], .int(MCPProtocolHandler.toolsListTTLMilliseconds))
        XCTAssertEqual(result?["cacheScope"], "private")
    }

    func testUnsupportedModernVersion() {
        var session = MCPSessionState()
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2030-01-01", "io.modelcontextprotocol/clientCapabilities": [:]]
        let error = reply(handler.handle(request(4, "tools/list", ["_meta": meta]), session: &session))["error"]

        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.unsupportedProtocolVersion)))
        XCTAssertEqual(error?["data"]?["requested"], "2030-01-01")
        XCTAssertEqual(error?["data"]?["supported"]?.arrayValue?.first, "2026-07-28")
    }

    func testModernRequestWithoutCapabilitiesIsInvalidParams() {
        var session = MCPSessionState()
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
        let error = reply(handler.handle(request(5, "tools/list", ["_meta": meta]), session: &session))["error"]
        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
    }

    func testRequestWithoutHandshakeOrMetaNamesSupportedVersions() {
        var session = MCPSessionState()
        let error = reply(handler.handle(request(6, "tools/call", ["name": "a_tool"]), session: &session))["error"]

        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
        XCTAssertTrue(error?["message"]?.stringValue?.contains("2026-07-28") == true)
        XCTAssertTrue(error?["message"]?.stringValue?.contains("2025-11-25") == true)
    }

    // MARK: - Tool calls

    func testToolCallIsHandedBack() {
        var session = MCPSessionState()
        let dispatch = handler.handle(request(7, "tools/call", ["name": "a_tool", "arguments": ["x": 1], "_meta": modernMeta]), session: &session)
        XCTAssertEqual(dispatch, .callTool(id: 7, name: "a_tool", arguments: ["x": 1], modern: true))
    }

    func testUnknownToolAndBadArguments() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let unknown = reply(handler.handle(request(8, "tools/call", ["name": "nope"]), session: &session))
        XCTAssertEqual(unknown["error"]?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))

        let bad = reply(handler.handle(request(9, "tools/call", ["name": "a_tool", "arguments": "x"]), session: &session))
        XCTAssertEqual(bad["error"]?["code"], .int(Int64(JSONRPCErrorCode.invalidParams)))
    }

    func testUnknownMethod() {
        var session = MCPSessionState(era: .legacy(version: "2025-11-25"))
        let error = reply(handler.handle(request(10, "resources/list"), session: &session))["error"]
        XCTAssertEqual(error?["code"], .int(Int64(JSONRPCErrorCode.methodNotFound)))
    }

    func testCancellationNotification() {
        var session = MCPSessionState()
        let dispatch = handler.handle(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]], session: &session)
        XCTAssertEqual(dispatch, .cancel(requestID: 7))
    }

    func testToolResultShapes() {
        let success = MCPToolResult.success(["count": 2])
        let modern = handler.toolCallResponse(id: 1, result: success, modern: true)["result"]
        XCTAssertEqual(modern?["structuredContent"], ["count": 2])
        XCTAssertEqual(modern?["content"]?.arrayValue?.first?["text"], #"{"count":2}"#)
        XCTAssertEqual(modern?["isError"], false)
        XCTAssertEqual(modern?["resultType"], "complete")

        let legacy = handler.toolCallResponse(id: 1, result: .failure("nope"), modern: false)["result"]
        XCTAssertEqual(legacy?["isError"], true)
        XCTAssertNil(legacy?["structuredContent"])
        XCTAssertNil(legacy?["resultType"])
    }
}
