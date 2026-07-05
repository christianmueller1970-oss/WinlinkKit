import Foundation
import Network

/// A plain TCP byte stream (NWConnection) as a `WinlinkTransport`.
///
/// Used directly by `TelnetTransport` (CMS) and twice by `VaraModem`
/// (command + data channel).
public actor TCPTransport: WinlinkTransport {
    private let connection: NWConnection
    private var isClosed = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connects to the given host/port, awaiting the ready state.
    public static func connect(
        host: String, port: UInt16, timeout: TimeInterval = 30
    ) async throws -> TCPTransport {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: nil, tcp: tcp)
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    cont.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: WinlinkError.connectionClosed)
                case .waiting(let error):
                    // NWConnection retries on "waiting" (e.g. connection
                    // refused) until the network changes. Fail fast instead,
                    // like Go's net.Dial — retrying is the caller's job.
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    cont.resume(throwing: error)
                default:
                    break // .setup, .preparing — keep waiting.
                }
            }
            connection.start(queue: .global())
        }

        return TCPTransport(connection: connection)
    }

    public func read() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else {
                    // isComplete without data: remote closed the connection.
                    _ = isComplete
                    cont.resume(returning: Data())
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }
}
