// Ported from wl2k-go/lzhuf/bit_reader.go (itself derived from Go's bzip2).
//
// Deviation from Go: reads from an in-memory byte array instead of an
// io.Reader, and throws on exhaustion instead of latching an error flag —
// the whole compressed image is always available in our Data-based API.

/// Reads values bit-by-bit from a byte buffer, MSB first.
struct BitReader {
    private let bytes: [UInt8]
    private var index: Int
    private var n: UInt64 = 0
    private var bits: Int = 0

    init(_ bytes: [UInt8], startingAt index: Int = 0) {
        self.bytes = bytes
        self.index = index
    }

    /// Reads `count` bits (max 32) into the least-significant part of an Int.
    mutating func readBits(_ count: Int) throws -> Int {
        while bits < count {
            guard index < bytes.count else {
                throw WinlinkError.malformedInput("lzhuf: unexpected end of compressed stream")
            }
            n = (n << 8) | UInt64(bytes[index])
            index += 1
            bits += 8
        }
        // Right-shift the desired bits into the least-significant places
        // and mask off anything above.
        let value = (n >> UInt64(bits - count)) & ((1 << UInt64(count)) - 1)
        bits -= count
        return Int(value)
    }

    mutating func readBit() throws -> Int {
        try readBits(1)
    }
}
