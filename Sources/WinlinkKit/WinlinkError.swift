import Foundation

/// Typed errors for the protocol path. Never `fatalError` in protocol code.
public enum WinlinkError: Error, Sendable, Equatable {
    /// The remote SID does not advertise the required B2 feature.
    case unsupportedRemoteSID(String)
    /// The connection was closed unexpectedly.
    case connectionClosed
    /// A protocol line or frame could not be parsed.
    case malformedInput(String)
    /// A CRC16 or size check failed (LZHUF/B2 framing).
    case invalidChecksum
    /// The message violates a Winlink Message Structure constraint
    /// (Go: ValidationError).
    case validation(field: String, reason: String)
}
