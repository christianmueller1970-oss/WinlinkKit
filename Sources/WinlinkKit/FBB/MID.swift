// Ported from wl2k-go/fbb/mid.go
import CryptoKit
import Foundation

let MaxMIDLength = 12

/// Generates a unique message ID in the format specified by the protocol:
/// MD5 over "<timestamp>-<callsign>", Base32-encoded, truncated to 12 characters.
func generateMID(callsign: String, date: Date = Date()) -> String {
    let sum = Array(Insecure.MD5.hash(data: Data(midPayload(callsign: callsign, date: date))))
    return String(Base32.encode(sum).prefix(MaxMIDLength))
}

/// Deviation from Go: wl2k-go feeds `time.Time.String()` (which includes a
/// monotonic clock reading) into the hash. The exact textual form only matters
/// for uniqueness, not for interoperability, so we use the Unix timestamp with
/// nanosecond precision instead.
func midPayload(callsign: String, date: Date) -> [UInt8] {
    let timestamp = String(format: "%.9f", date.timeIntervalSince1970)
    return Array("\(timestamp)-\(callsign)".utf8)
}
