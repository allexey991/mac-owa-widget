import Foundation
import Network

/// Minimal HTTP/1.1 server on `127.0.0.1:<port>` for the ICS feed: one request per connection,
/// response, close.
///
/// Calendar.app's subscriber (`dataaccessd`) first tries TLS on an `http://` address: it sends a
/// ClientHello, gets the plain-text 400 this listener answers with, and retries over plain http
/// (verified on a probe, 2026-10-17). Anything that is not HTTP is therefore answered and closed
/// immediately rather than left to the read timeout.
final class ICSFeedListener: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case ready(UInt16)
        case portInUse
        case failed(String)
    }

    typealias Responder = @Sendable (ICSHTTPRequest) async -> ICSHTTPResponse

    static let readTimeout: TimeInterval = 5
    static let maxConnections = 4

    private let port: UInt16
    private let respond: Responder
    private let onState: @Sendable (State) -> Void
    /// Serializes all mutable state below and every Network.framework callback.
    private let queue = DispatchQueue(label: "com.owawidget.icsfeed.listener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16, respond: @escaping Responder, onState: @escaping @Sendable (State) -> Void) {
        self.port = port
        self.respond = respond
        self.onState = onState
    }

    func start() throws {
        let parameters = NWParameters.tcp
        // Bound to the loopback address itself, not to every interface: nothing off this Mac
        // can connect, whatever the firewall says.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in self?.handle(listenerState: state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Listener

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            onState(.ready(listener?.port?.rawValue ?? port))
        case .failed(let error), .waiting(let error):
            // `.waiting` on a listener means it could not bind and would retry forever; the
            // settings tab should say so instead.
            listener?.cancel()
            listener = nil
            if case .posix(let code) = error, code == .EADDRINUSE {
                onState(.portInUse)
            } else {
                onState(.failed(error.localizedDescription))
            }
        default:
            break
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard isLoopback(connection.endpoint), connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self] in
            // A client that never finishes its request does not get to hold a slot.
            self?.connections[id]?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch ICSHTTPRequestParser.parse(buffer) {
            case .complete(let request):
                let respond = self.respond
                Task {
                    let response = await respond(request)
                    self.queue.async { self.send(response, on: connection) }
                }
            case .notHTTP, .tooLarge:
                self.send(ICSFeedRouter.badRequest, on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: ICSHTTPResponse, on connection: NWConnection) {
        connection.send(content: ICSFeedRouter.serialize(response), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}
