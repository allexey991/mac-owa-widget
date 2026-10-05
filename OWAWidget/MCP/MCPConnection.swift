import Foundation
import OWAWidgetMCPShared

/// One client connection: reads lines, runs them through `MCPProtocolHandler` in order, and runs
/// tool calls concurrently so a slow network tool does not hold up `tools/list`.
actor MCPConnection {
    private let channel: MCPSocketChannel
    private let handler: MCPProtocolHandler
    private let tools: any MCPToolProviding
    private let onClientIdentified: @Sendable (String) -> Void

    private var session = MCPSessionState()
    private var isFirstLine = true
    private var clientLabel: String?
    private var labelFromProtocol = false
    /// Running tool calls by the canonical JSON of their request id. Removing an entry is what
    /// cancels a call's answer: `finish` only replies for ids still present.
    private var running: [String: Task<Void, Never>] = [:]

    init(
        channel: MCPSocketChannel,
        handler: MCPProtocolHandler,
        tools: any MCPToolProviding,
        onClientIdentified: @escaping @Sendable (String) -> Void
    ) {
        self.channel = channel
        self.handler = handler
        self.tools = tools
        self.onClientIdentified = onClientIdentified
    }

    func run() async {
        for await line in channel.lines() {
            receive(line)
        }
        for task in running.values { task.cancel() }
        running.removeAll()
        channel.close()
    }

    func receive(_ line: Data) {
        if isFirstLine {
            isFirstLine = false
            if let hello = MCPBridgeHello.decode(line) {
                identify(Self.label(forParentPath: hello.parent_path), fromProtocol: false)
                return
            }
        }

        guard let message = JSONLine.decode(line) else {
            channel.send(JSONLine.encode(JSONRPC.error(id: .null, code: JSONRPCErrorCode.parseError, message: "Parse error")))
            return
        }
        if let name = Self.clientName(in: message) {
            identify(name, fromProtocol: true)
        }

        switch handler.handle(message, session: &session) {
        case .none:
            break
        case .reply(let response):
            channel.send(JSONLine.encode(response))
        case .cancel(let requestID):
            let key = JSONLine.encodeString(requestID)
            running.removeValue(forKey: key)?.cancel()
        case .callTool(let id, let name, let arguments, let modern):
            let key = JSONLine.encodeString(id)
            let tools = self.tools
            let handler = self.handler
            let client = clientLabel
            running[key] = Task { [weak self] in
                let result = await tools.callTool(name: name, arguments: arguments, client: client)
                guard !Task.isCancelled else { return }
                await self?.finish(key: key, response: handler.toolCallResponse(id: id, result: result, modern: modern))
            }
        }
    }

    private func finish(key: String, response: JSONValue) {
        // Gone means cancelled: the spec forbids any further message for a cancelled request.
        guard running.removeValue(forKey: key) != nil else { return }
        channel.send(JSONLine.encode(response))
    }

    private func identify(_ label: String, fromProtocol: Bool) {
        // The MCP client name (from initialize / _meta) beats the parent-process guess.
        guard !label.isEmpty, !(labelFromProtocol && !fromProtocol), label != clientLabel else { return }
        clientLabel = label
        labelFromProtocol = fromProtocol
        onClientIdentified(label)
    }

    // MARK: - Labels

    static func clientName(in message: JSONValue) -> String? {
        let params = message["params"]
        let info = params?["clientInfo"] ?? params?["_meta"]?["io.modelcontextprotocol/clientInfo"]
        let title = info?["title"]?.stringValue
        let name = info?["name"]?.stringValue
        return (title?.isEmpty == false ? title : name).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "/Applications/Claude.app/Contents/MacOS/Claude" -> "Claude"; "/usr/local/bin/claude" -> "claude".
    static func label(forParentPath path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let components = URL(fileURLWithPath: path).pathComponents
        if let app = components.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return components.last ?? ""
    }
}
