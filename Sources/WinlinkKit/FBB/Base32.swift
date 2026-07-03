// Small replacement for Go's encoding/base32 StdEncoding (RFC 4648).
// Only encoding is needed (for MID generation).
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Encodes bytes as standard Base32 with `=` padding.
    static func encode(_ bytes: [UInt8]) -> String {
        var output = [Character]()
        output.reserveCapacity((bytes.count + 4) / 5 * 8)

        var buffer = 0
        var bitsInBuffer = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                bitsInBuffer -= 5
                output.append(alphabet[(buffer >> bitsInBuffer) & 0x1f])
            }
        }
        if bitsInBuffer > 0 {
            output.append(alphabet[(buffer << (5 - bitsInBuffer)) & 0x1f])
        }
        while output.count % 8 != 0 {
            output.append("=")
        }
        return String(output)
    }
}
