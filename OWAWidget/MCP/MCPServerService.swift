import Foundation
import OWAWidgetMCPShared

/// Owns the MCP socket for the app's lifetime and publishes its state to the settings tab.
///
/// The listener runs whenever the app runs, even with the feature off: a disabled server answers
/// every tool call with "turned off in Settings", which is the only way a user looking at an MCP
/// client can learn where the switch is. It never returns calendar data while disabled.
@MainActor
final class MCPServerService: ObservableObject {
    static let shared = MCPServerService()
    static let enabledDefaultsKey = "mcpServerEnabled"
    static let journalLimit = 50

    enum Status: Equatable {
        case stopped
        case listening
        case unavailable(String)
    }

    struct JournalEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let tool: String
        let client: String?
        let isError: Bool
    }

    struct Client: Identifiable, Equatable {
        let id: UUID
        var label: String
        let connectedAt: Date
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var clients: [Client] = []
    /// In memory only: who called which tool, never arguments or results.
    @Published private(set) var journal: [JournalEntry] = []
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: MCPServerService.enabledDefaultsKey) {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            MCPDebugLog.log("enabled=\(isEnabled)")
        }
    }

    private(set) var socketPath: String = ""
    private var listener: MCPSocketListener?
    private var watchdog: Timer?
    private var toolbox: MCPToolbox?
    private var handler: MCPProtocolHandler?

    private init() {}

    /// Starts listening. Called from the menu-bar label's `onAppear`, which runs at launch;
    /// later calls are no-ops.
    func start(calendarService: CalendarService) {
        guard toolbox == nil else { return }
        MCPDebugLog.reset()

        let calendarTools = MCPCalendarTools(
            calendarService: calendarService,
            isEnabled: { UserDefaults.standard.bool(forKey: MCPServerService.enabledDefaultsKey) }
        )
        toolbox = MCPToolbox(calendarTools: calendarTools) { tool, client, isError in
            MCPServerService.shared.record(tool: tool, client: client, isError: isError)
        }
        let info = Bundle.main.infoDictionary
        handler = MCPProtocolHandler(
            serverName: "owa-widget",
            serverTitle: "OWA Widget",
            serverVersion: (info?["CFBundleShortVersionString"] as? String) ?? "dev",
            instructions: MCPToolRegistry.instructions,
            tools: MCPToolRegistry.tools
        )

        let bundleID = Bundle.main.bundleIdentifier ?? "com.owawidget.MacOwaWidget"
        socketPath = MCPSocketPath.socketURL(
            bundleIdentifier: bundleID,
            homeDirectory: MCPSocketPath.userHomeDirectory()
        ).path
        startListener()

        // Cache cleaners or a second copy of the app can delete or replace the socket file;
        // without this the server would go silently unreachable until the next launch.
        watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MCPServerService.shared.checkSocket() }
        }
    }

    /// Path of the bridge binary inside this bundle, for the configuration snippets.
    var bridgePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/owawidget-mcp", isDirectory: false)
            .path
    }

    var isBridgeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: bridgePath)
    }

    // MARK: - Listener

    private func startListener() {
        guard let toolbox, let handler else { return }
        guard MCPSocketPath.fitsSocketAddress(URL(fileURLWithPath: socketPath)) else {
            status = .unavailable("Socket path is too long: \(socketPath)")
            MCPDebugLog.log("socket path too long: \(socketPath.utf8.count) bytes")
            return
        }
        let listener = MCPSocketListener(path: socketPath) { channel in
            Task { @MainActor in
                MCPServerService.shared.accept(channel, toolbox: toolbox, handler: handler)
            }
        }
        do {
            try listener.start()
            self.listener = listener
            status = .listening
            MCPDebugLog.log("listening at \(socketPath)")
        } catch {
            status = .unavailable(error.localizedDescription)
            MCPDebugLog.log("listen failed: \(error.localizedDescription)")
        }
    }

    /// Rebinds a running listener whose socket file vanished or was replaced. A listener that
    /// never started (path too long, another copy serving) stays down: retrying every minute
    /// would only repeat the same failure in the log.
    private func checkSocket() {
        guard let listener, !listener.isSocketFileIntact else { return }
        MCPDebugLog.log("socket file missing or replaced, rebinding")
        listener.stop()
        self.listener = nil
        startListener()
    }

    private func accept(_ channel: MCPSocketChannel, toolbox: MCPToolbox, handler: MCPProtocolHandler) {
        let clientID = UUID()
        clients.append(Client(id: clientID, label: "", connectedAt: Date()))
        MCPDebugLog.log("client connected (\(clients.count) active)")
        let connection = MCPConnection(channel: channel, handler: handler, tools: toolbox) { label in
            Task { @MainActor in MCPServerService.shared.label(clientID, label) }
        }
        Task {
            await connection.run()
            await MainActor.run { MCPServerService.shared.disconnected(clientID) }
        }
    }

    private func label(_ id: UUID, _ label: String) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[index].label = label
    }

    private func disconnected(_ id: UUID) {
        clients.removeAll { $0.id == id }
        MCPDebugLog.log("client disconnected (\(clients.count) active)")
    }

    private func record(tool: String, client: String?, isError: Bool) {
        MCPDebugLog.log("call \(tool) client=\(client ?? "-") error=\(isError)")
        journal.insert(JournalEntry(date: Date(), tool: tool, client: client, isError: isError), at: 0)
        if journal.count > Self.journalLimit {
            journal.removeLast(journal.count - Self.journalLimit)
        }
    }
}
