// Ported from wl2k-go/fbb/helpers.go (line reading) and bufio usage in wl2k.go
import Foundation

/// Buffered byte/line reader on top of a `WinlinkTransport`.
///
/// Provides the primitives the B2F session needs: single bytes,
/// one-byte peek (Go: bufio.Reader.Peek) and CR-terminated protocol
/// lines (Go: bufio.Reader.ReadString).
final class TransportReader {
    private let transport: any WinlinkTransport
    private var buffer = [UInt8]()
    private var pos = 0

    init(_ transport: any WinlinkTransport) {
        self.transport = transport
    }

    /// Ensures at least one unread byte is buffered.
    private func fill() async throws {
        while pos >= buffer.count {
            let chunk = try await transport.read()
            guard !chunk.isEmpty else {
                throw WinlinkError.connectionClosed
            }
            buffer = [UInt8](chunk)
            pos = 0
        }
    }

    /// Returns the next byte without consuming it.
    func peekByte() async throws -> UInt8 {
        try await fill()
        return buffer[pos]
    }

    /// Consumes and returns the next byte.
    func readByte() async throws -> UInt8 {
        try await fill()
        defer { pos += 1 }
        return buffer[pos]
    }

    /// Reads bytes up to (excluding) the given delimiter; the delimiter
    /// itself is consumed.
    func readBytes(until delimiter: UInt8) async throws -> [UInt8] {
        var out = [UInt8]()
        while true {
            let b = try await readByte()
            if b == delimiter {
                return out
            }
            out.append(b)
        }
    }

    /// Reads a CR-terminated protocol line and cleans it up
    /// (Go: rd.ReadString('\r') + cleanString). Protocol lines are
    /// ISO-8859-1 encoded.
    func readLine() async throws -> String {
        let bytes = try await readBytes(until: FBBControl.cr)
        return Self.cleanString(B2Charset.decode(bytes))
    }

    /// Trims whitespace and strips stray NUL bytes (Go: cleanString,
    /// ported 1:1 including the drop-last-two quirk on a trailing NUL).
    static func cleanString(_ string: String) -> String {
        var str = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.first == "\0" {
            str.removeFirst()
        }
        if str.last == "\0" {
            str = String(str.dropLast(2))
        }
        return str
    }
}

/// Control bytes of the FBB binary transfer framing (Go: _CHRNUL etc.)
/// plus the protocol line ending — a single CR, never CRLF.
enum FBBControl {
    static let nul: UInt8 = 0
    static let soh: UInt8 = 1
    static let stx: UInt8 = 2
    static let eot: UInt8 = 4
    static let cr: UInt8 = 0x0D
}

/// The protocol line terminator as a string, for composing outbound lines.
let protocolCR = "\r"
