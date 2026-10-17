import Foundation
import os.log

/// Serves Exchange meetings to Calendar.app as an ICS subscription on `http://127.0.0.1`
/// (design: `docs/superpowers/specs/2026-10-18-ics-feed-design.md`).
///
/// Unlike the MCP socket, the listener runs only while the feature is on: there is nobody to
/// explain the switch to, and a closed port is the cheapest way to serve nothing.
@MainActor
final class ICSFeedService: ObservableObject {
    static let shared = ICSFeedService()

    enum Status: Equatable {
        case stopped
        case starting
        case listening
        case portInUse(UInt16)
        case failed(String)
    }

    /// Last request seen, for the settings tab. No event data, only who asked and what they got.
    struct LastRequest: Equatable {
        let date: Date
        let status: Int
        let client: String?
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastRequest: LastRequest?
    @Published private(set) var port: UInt16
    /// `nil` while the feature is off: reading the token touches the Keychain-backed store, and a
    /// user who never turns the feed on should never be asked about it.
    @Published private(set) var feedURL: URL?
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings.isEnabled = isEnabled
            ICSFeedDebugLog.log("enabled=\(isEnabled)")
            restart()
        }
    }

    private let settings: ICSFeedSettings
    private weak var calendarService: CalendarService?
    private var strings: () -> ICSFeedStrings = { ICSFeedService.fallbackStrings }
    private var listener: ICSFeedListener?
    private var config: ICSFeedRouteConfig?
    /// Bumped on every (re)start so late state callbacks of a replaced listener are ignored.
    private var generation = 0
    private var started = false

    private init(settings: ICSFeedSettings = ICSFeedSettings()) {
        self.settings = settings
        self.port = settings.port
        self.isEnabled = settings.isEnabled
    }

    /// Called once at launch, next to `MCPServerService.start`; later calls are no-ops.
    func start(calendarService: CalendarService, localization: LocalizationService) {
        guard !started else { return }
        started = true
        ICSFeedDebugLog.reset()
        self.calendarService = calendarService
        self.strings = { [weak localization] in
            guard let localization else { return ICSFeedService.fallbackStrings }
            return ICSFeedStrings(
                cancelledPrefix: localization.tr("icsFeed.event.cancelledPrefix"),
                declinedPrefix: localization.tr("icsFeed.event.declinedPrefix"),
                organizerLabel: localization.tr("icsFeed.event.organizer"),
                attendeesLabel: localization.tr("icsFeed.event.attendees")
            )
        }
        restart()
    }

    /// Changes the port. The subscription URL changes with it.
    func setPort(_ newPort: UInt16) {
        guard newPort != port, newPort > 0 else { return }
        settings.port = newPort
        port = newPort
        ICSFeedDebugLog.log("port=\(newPort)")
        restart()
    }

    /// Issues a new secret path; the old subscription stops working.
    func regenerateAddress() {
        settings.regenerateToken()
        ICSFeedDebugLog.log("token regenerated")
        restart()
    }

    /// Retries after a failure (for instance once the other app holding the port has quit).
    func retry() {
        restart()
    }

    // MARK: - Listener lifecycle

    private func restart() {
        stopListener()
        guard started, isEnabled else {
            status = .stopped
            feedURL = nil
            return
        }
        let config = ICSFeedRouteConfig(token: settings.token(), port: port)
        self.config = config
        feedURL = config.url
        generation += 1
        let generation = generation
        status = .starting

        let listener = ICSFeedListener(
            port: port,
            respond: { request in
                await ICSFeedService.shared.respond(to: request, config: config)
            },
            onState: { state in
                Task { @MainActor in ICSFeedService.shared.listenerStateChanged(state, generation: generation) }
            }
        )
        do {
            try listener.start()
            self.listener = listener
        } catch {
            status = .failed(error.localizedDescription)
            ICSFeedDebugLog.log("listener init failed: \(error.localizedDescription)")
        }
    }

    private func stopListener() {
        listener?.stop()
        listener = nil
        config = nil
    }

    private func listenerStateChanged(_ state: ICSFeedListener.State, generation: Int) {
        guard generation == self.generation, listener != nil else { return }
        switch state {
        case .ready(let boundPort):
            status = .listening
            ICSFeedDebugLog.log("listening on 127.0.0.1:\(boundPort)")
        case .portInUse:
            status = .portInUse(port)
            listener = nil
            ICSFeedDebugLog.log("port \(port) in use")
        case .failed(let message):
            status = .failed(message)
            listener = nil
            ICSFeedDebugLog.log("listener failed: \(message)")
        }
    }

    // MARK: - Requests

    private func respond(to request: ICSHTTPRequest, config: ICSFeedRouteConfig) -> ICSHTTPResponse {
        let response = ICSFeedRouter.respond(to: request, config: config, snapshot: snapshot())
        lastRequest = LastRequest(date: Date(), status: response.status, client: request.userAgent)
        // Never the path: it carries the token.
        ICSFeedDebugLog.log("\(request.method) -> \(response.status) bytes=\(response.body.count) ua=\(request.userAgent ?? "-")")
        return response
    }

    private func snapshot() -> ICSFeedSnapshot {
        ICSFeedSnapshot(
            events: calendarService?.events ?? [],
            feedAccountIDs: ICSFeedSettings.feedAccountIDs(calendarService?.accounts ?? []),
            hasData: calendarService?.eventCoverage != nil,
            generatedAt: Date(),
            timeZone: AppTimeZone.zone,
            strings: strings()
        )
    }

    private nonisolated static let fallbackStrings = ICSFeedStrings(
        cancelledPrefix: "Cancelled: ",
        declinedPrefix: "Declined: ",
        organizerLabel: "Organizer",
        attendeesLabel: "Attendees"
    )
}

enum ICSFeedDebugLog {
    static let logger = Logger(subsystem: "com.owawidget", category: "ICSFeed")

    #if DEBUG
    private static let url = URL(fileURLWithPath: "/tmp/owawidget_icsfeed.log")
    private static let lock = NSLock()

    static func reset() {
        try? "=== ICS Feed Log started \(Date()) ===\n".write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        guard let data = "[\(formatter.string(from: Date()))] \(message)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
    #else
    static func reset() {}
    static func write(_ message: String) {}
    #endif

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write(message)
    }
}
