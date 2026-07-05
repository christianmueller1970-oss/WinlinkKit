// Ported from wl2k-go/transport/ardop/frame.go — MIT, © 2015 Martin Hebnes Pedersen (LA5NTA)
import Foundation

/// Framing of the ARDOP TCP data channel.
///
/// Host → TNC: `[2-byte big-endian length][payload]` where length is the
/// payload byte count (Go: tncConn.Write).
///
/// TNC → host: `[2-byte big-endian length][3-char type][payload]` where
/// length covers type and payload; the type is "ARQ", "FEC", "ERR" or
/// "IDF" (Go: readFrameOfType, case 'd').
///
/// Serial transports additionally carry "D:" prefixes and CRC16
/// trailers — not implemented, WinlinkKit is TCP-only.
enum ArdopFraming {
    /// Maximum payload of one frame (the length field is a uint16).
    static let maxPayload = 65535

    /// Encodes one host → TNC data frame.
    static func encode(_ payload: Data) -> Data {
        precondition(payload.count <= maxPayload, "ARDOP frame payload too large")
        var frame = Data(capacity: payload.count + 2)
        frame.append(UInt8(payload.count >> 8))
        frame.append(UInt8(payload.count & 0xff))
        frame.append(payload)
        return frame
    }

    /// Incremental decoder for TNC → host data frames, reassembling
    /// frames across arbitrary TCP chunk boundaries.
    struct Decoder {
        private var buffer = [UInt8]()

        mutating func append(_ chunk: Data) {
            buffer.append(contentsOf: chunk)
        }

        /// Returns the next complete frame, or nil if more bytes are
        /// needed. A frame too short for its 3-char type marker is a
        /// protocol error and yields an empty type.
        mutating func next() -> (type: String, payload: Data)? {
            guard buffer.count >= 2 else { return nil }
            let length = Int(buffer[0]) << 8 | Int(buffer[1])
            guard buffer.count >= 2 + length else { return nil }

            let body = Array(buffer[2..<(2 + length)])
            buffer.removeFirst(2 + length)

            guard length >= 3 else {
                return (type: "", payload: Data())
            }
            return (
                type: String(decoding: body.prefix(3), as: UTF8.self),
                payload: Data(body.dropFirst(3))
            )
        }
    }
}
