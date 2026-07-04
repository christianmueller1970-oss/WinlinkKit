// Ported from wl2k-go/fbb/message.go (Address parts)
import Foundation

/// Representation of a receiver/sender address.
public struct Address: Equatable, Hashable, Sendable {
    /// The transport protocol prefix (e.g. `SMTP`); empty for Winlink addresses.
    public var proto: String
    /// The address part: a callsign (`HB9HJI`) or an email address.
    public var addr: String

    public init(proto: String = "", addr: String) {
        self.proto = proto
        self.addr = addr
    }

    /// Constructs a proper Address from a string.
    ///
    /// Supported formats: `foo@bar.baz` (SMTP proto), `N0CALL` (short
    /// winlink address) or `N0CALL@winlink.org` (full winlink address).
    public init(string: String) {
        let colonParts = string.split(separator: ":", omittingEmptySubsequences: false)
        let atParts = string.split(separator: "@", omittingEmptySubsequences: false)

        if colonParts.count == 2 {
            self.init(proto: String(colonParts[0]), addr: String(colonParts[1]))
        } else if atParts.count == 1 {
            self.init(addr: string)
        } else if atParts[1].caseInsensitiveCompare("winlink.org") == .orderedSame {
            self.init(addr: String(atParts[0]))
        } else {
            self.init(proto: "SMTP", addr: string)
        }

        if proto.isEmpty {
            addr = addr.uppercased()
        }
    }

    /// True if the Address is unset.
    public var isZero: Bool { addr.isEmpty }
}

extension Address: CustomStringConvertible {
    /// Textual representation, e.g. `LA5NTA` or `SMTP:foo@bar.baz`.
    public var description: String {
        proto.isEmpty ? addr : "\(proto):\(addr)"
    }
}
