import Foundation

/// Abstraction over the byte stream a B2F session runs on.
///
/// Stage 1 provides a Telnet/TCP implementation; radio transports
/// (VARA, ARDOP, AX.25/AGWPE) plug in later behind this same interface.
/// `B2FSession` must only ever talk to this protocol, never to a
/// concrete network type.
public protocol WinlinkTransport: Sendable {
    /// Reads the next chunk of available bytes.
    /// Returns an empty `Data` when the remote side closed the connection.
    func read() async throws -> Data

    /// Writes all given bytes to the connection.
    func write(_ data: Data) async throws

    /// Closes the connection. Must be safe to call more than once.
    func close() async
}
