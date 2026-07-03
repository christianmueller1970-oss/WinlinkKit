// Ported from wl2k-go/lzhuf/lzhuf.go, reader.go and writer.go
//
// LZHUF: LZ77 with a 2048-byte ring buffer and adaptive Huffman coding,
// as used by the binary FBB protocols B, B1 and B2. In B2 mode a CRC16
// of the compressed image (size header + data) is prepended.
//
// Deviation from Go: the streaming io.Reader/io.Writer API is replaced by
// whole-buffer encode/decode. In B2F the compressed sizes are known from
// the proposals, so the session layer can always present complete buffers.
// The bit-level algorithm is ported 1:1.

import Foundation

// LZHUF constants (Go: _N, _F, ...; names kept, underscores dropped)
private let N = 2048                     // Buffer size
private let F = 60                       // Lookahead buffer size
private let NIL = N                      // Leaf of tree
private let Threshold = 2
private let NumChar = 256 - Threshold + F // Kinds of characters (0..NumChar-1)
private let T = (NumChar * 2) - 1        // Size of table
private let R = T - 1                    // Position of root
private let MaxFreq = 0x8000             // Tree is rebuilt when freq[R] reaches this

/// Whole-buffer LZHUF encode/decode.
enum LZHUF {
    /// Compresses `data`. With `b2` a CRC16 of the compressed image is prepended.
    static func encode(_ data: Data, b2: Bool = true) -> Data {
        let encoder = Encoder()
        encoder.write([UInt8](data))
        return Data(encoder.close(b2: b2))
    }

    /// Decompresses `data`, verifying the CRC16 (`b2`) and size headers.
    static func decode(_ data: Data, b2: Bool = true) throws -> Data {
        try Data(Decoder.decode([UInt8](data), b2: b2))
    }
}

// MARK: - Shared tree state

/// The LZ77 ring buffer and adaptive Huffman tree (Go: struct lzhuf).
private final class Tree {
    // Frequency table.
    var freq = [Int](repeating: 0, count: T + 1)

    // Pointers to parent nodes.
    // Except for the elements [T..T+NumChar-1] which are
    // used to get the positions of leaves corresponding to the codes.
    var prnt = [Int](repeating: 0, count: T + NumChar)

    // Pointers to child nodes.
    var son = [Int](repeating: 0, count: T)

    var dad = [Int](repeating: 0, count: N + 1)
    var lson = [Int](repeating: 0, count: N + 1)
    var rson = [Int](repeating: 0, count: N + 257)

    var textBuf = [UInt8](repeating: 0, count: N + F - 1)
    var matchLength = 0
    var matchPosition = 0

    // Go: newLZHUFF()
    init() {
        for i in 0..<NumChar {
            freq[i] = 1
            son[i] = i + T
            prnt[i + T] = i
        }

        var i = 0
        var j = NumChar
        while j <= R {
            freq[j] = freq[i] + freq[i + 1]
            son[j] = i
            prnt[i] = j
            prnt[i + 1] = j
            i += 2
            j += 1
        }
        freq[T] = 0xffff
        prnt[R] = 0
    }

    // Go: InitTree() — only needed by the encoder's binary search tree.
    func initTree() {
        for i in (N + 1)...(N + 256) {
            rson[i] = NIL // root
        }
        for i in 0..<N {
            dad[i] = NIL // node
        }
    }

    // Delete from tree (Go: DeleteNode)
    func deleteNode(_ p: Int) {
        if dad[p] == NIL {
            return // not registered
        }

        var q: Int
        if rson[p] == NIL {
            q = lson[p]
        } else if lson[p] == NIL {
            q = rson[p]
        } else {
            q = lson[p]
            if rson[q] != NIL {
                while rson[q] != NIL {
                    q = rson[q]
                }
                rson[dad[q]] = lson[q]
                dad[lson[q]] = dad[q]
                lson[q] = lson[p]
                dad[lson[p]] = q
            }
            rson[q] = rson[p]
            dad[rson[p]] = q
        }

        dad[q] = dad[p]
        if rson[dad[p]] == p {
            rson[dad[p]] = q
        } else {
            lson[dad[p]] = q
        }

        dad[p] = NIL
    }

    // Insert to tree (Go: InsertNode). Also updates matchLength/matchPosition.
    func insertNode(_ r: Int) {
        var cmp = 1
        var p = N + 1 + Int(textBuf[r])
        rson[r] = NIL
        lson[r] = NIL
        matchLength = 0

        while true {
            if cmp >= 0 {
                if rson[p] != NIL {
                    p = rson[p]
                } else {
                    rson[p] = r
                    dad[r] = p
                    return
                }
            } else {
                if lson[p] != NIL {
                    p = lson[p]
                } else {
                    lson[p] = r
                    dad[r] = p
                    return
                }
            }

            var i = 1
            while i < F {
                cmp = Int(textBuf[r + i]) - Int(textBuf[p + i])
                if cmp != 0 {
                    break
                }
                i += 1
            }

            if i > Threshold {
                if i > matchLength {
                    matchPosition = ((r - p) & (N - 1)) - 1
                    matchLength = i
                    if matchLength >= F {
                        break
                    }
                }
                if i == matchLength {
                    let c = ((r - p) & (N - 1)) - 1
                    if c < matchPosition {
                        matchPosition = c
                    }
                }
            }
        }

        dad[r] = dad[p]
        lson[r] = lson[p]
        rson[r] = rson[p]
        dad[lson[p]] = r
        dad[rson[p]] = r
        if rson[dad[p]] == p {
            rson[dad[p]] = r
        } else {
            lson[dad[p]] = r
        }
        dad[p] = NIL // remove p
    }

    // Go: reconst()
    private func reconst() {
        // Collect leaf nodes in the first half of the table
        // and replace the freq by (freq + 1) / 2.
        var j = 0
        for i in 0..<T where son[i] >= T {
            freq[j] = (freq[i] + 1) / 2
            son[j] = son[i]
            j += 1
        }

        // Begin constructing tree by connecting children nodes.
        var i = 0
        j = NumChar
        while j < T {
            freq[j] = freq[i] + freq[i + 1]

            let first = freq[j]
            var k = j
            while first < freq[k - 1] {
                k -= 1
            }

            // Move [k..j-1] one slot right (Go: overlapping copy, so backwards).
            var m = j
            while m > k {
                freq[m] = freq[m - 1]
                son[m] = son[m - 1]
                m -= 1
            }
            freq[k] = first
            son[k] = i

            i += 2
            j += 1
        }

        // Connect parent nodes.
        for i in 0..<T {
            let k = son[i]
            if k >= T {
                prnt[k] = i
            } else {
                prnt[k + 1] = i
                prnt[k] = i
            }
        }
    }

    // Increment frequency of the given code and rebalance (Go: update).
    func update(_ code: Int) {
        if freq[R] == MaxFreq {
            reconst()
        }

        // Swap nodes to keep the tree freq-ordered.
        var c = prnt[code + T]
        while true {
            freq[c] += 1

            if freq[c] <= freq[c + 1] || freq.count <= c + 2 {
                c = prnt[c]
                if c == 0 {
                    break
                }
                continue // Order is ok
            }

            var l = c + 1
            let k = freq[c]
            while k > freq[l + 1] {
                l += 1
            }

            freq[c] = freq[l]
            freq[l] = k

            let i = son[c]
            prnt[i] = l
            if i < T {
                prnt[i + 1] = l
            }

            let j = son[l]
            son[l] = i

            prnt[j] = c
            if j < T {
                prnt[j + 1] = c
            }
            son[c] = j

            c = prnt[l]
            if c == 0 {
                break
            }
        }
    }
}

// MARK: - Decoder (Go: reader.go)

private enum Decoder {
    static func decode(_ bytes: [UInt8], b2: Bool) throws -> [UInt8] {
        var offset = 0

        // B2 header: CRC16 (2 bytes, little-endian) of everything that follows.
        if b2 {
            guard bytes.count >= 2 else {
                throw WinlinkError.malformedInput("lzhuf: missing crc16 header")
            }
            let expected = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            offset = 2
            // Deviation from Go: the checksum is verified up front over the
            // complete compressed image instead of tee-ing all bytes read.
            guard CRC16.checksum(bytes[offset...]) == expected else {
                throw WinlinkError.invalidChecksum
            }
        }

        // Size header: uncompressed size (4 bytes, little-endian).
        guard bytes.count >= offset + 4 else {
            throw WinlinkError.malformedInput("lzhuf: missing size header")
        }
        let size = Int(UInt32(bytes[offset]))
            | Int(UInt32(bytes[offset + 1])) << 8
            | Int(UInt32(bytes[offset + 2])) << 16
            | Int(UInt32(bytes[offset + 3])) << 24
        offset += 4

        let z = Tree()
        var r = N - R
        for i in 0..<(N - F) {
            z.textBuf[i] = 0x20 // ' '
        }

        var reader = BitReader(bytes, startingAt: offset)
        var out = [UInt8]()
        out.reserveCapacity(size)
        var pos = 0

        while pos < size {
            let c = try decodeChar(z, &reader)

            if c < 256 {
                out.append(UInt8(c))
                z.textBuf[r] = UInt8(c)
                r = (r + 1) & (N - 1)
                pos += 1
                continue
            }

            let i = (r - (try decodePosition(&reader)) - 1) & (N - 1)
            let j = c - 255 + Threshold
            for k in 0..<j {
                let byte = z.textBuf[(i + k) & (N - 1)]
                out.append(byte)
                z.textBuf[r] = byte
                r = (r + 1) & (N - 1)
                pos += 1
            }
        }

        // A match may overshoot the declared size on corrupt input
        // (Go detects this as a size mismatch on Close).
        guard pos == size else {
            throw WinlinkError.invalidChecksum
        }

        return out
    }

    private static func decodeChar(_ z: Tree, _ reader: inout BitReader) throws -> Int {
        var c = z.son[R]

        // Travel from root to leaf,
        // choosing the smaller child node (son[]) if the read bit is 0,
        // the bigger (son[]+1) if 1.
        while c < T {
            c += try reader.readBit()
            c = z.son[c]
        }
        c -= T
        z.update(c)
        return c
    }

    private static func decodePosition(_ reader: inout BitReader) throws -> Int {
        // Recover upper 6 bits from table.
        var i = try reader.readBits(8)
        let c = Int(dCode[i]) << 6

        // Read lower 6 bits verbatim.
        var j = Int(dLen[i]) - 2
        while j > 0 {
            i = (i << 1) + (try reader.readBit())
            j -= 1
        }
        return c | (i & 0x3f)
    }
}

// MARK: - Encoder (Go: writer.go)

private final class Encoder {
    private let z = Tree()
    private var buf = [UInt8]() // Compressed image (before headers)

    // Bit output buffer. Go uses a 64-bit uint here; bits above 15 are
    // shifted out and never read, matching the original C semantics.
    private var putbuf: UInt = 0
    private var putlen = 0

    private var len = 0
    private var r = N - F
    private var s = 0
    private var lastMatchLength = 0
    private var preFilled = false
    private var fileSize = 0

    init() {
        z.initTree()
        for i in 0..<r {
            z.textBuf[i] = 0x20 // ' '
        }
    }

    func write(_ p: [UInt8]) {
        var n = 0

        while !preFilled && n < p.count { // Pre-fill lookahead buffer
            z.textBuf[r + len] = p[n]
            n += 1
            fileSize += 1
            len += 1
            z.insertNode(r - len)

            lastMatchLength = 1
            preFilled = len == F
        }

        while n < p.count {
            advance(p[n])
            n += 1
            fileSize += 1
        }
    }

    /// Flushes remaining data and returns the complete compressed frame:
    /// [crc16 (b2 only)] + [size, 4 bytes LE] + [compressed image].
    func close(b2: Bool) -> [UInt8] {
        // Write remaining data from the lookahead buffer.
        while len > 0 {
            advance(nil)
        }
        encode()
        encodeEnd()

        let sizeBytes: [UInt8] = [
            UInt8(fileSize & 0xff),
            UInt8((fileSize >> 8) & 0xff),
            UInt8((fileSize >> 16) & 0xff),
            UInt8((fileSize >> 24) & 0xff),
        ]

        var out = [UInt8]()
        out.reserveCapacity(buf.count + 6)
        if b2 {
            let sum = CRC16.checksum(sizeBytes + buf)
            out.append(UInt8(sum & 0xff))
            out.append(UInt8(sum >> 8))
        }
        out.append(contentsOf: sizeBytes)
        out.append(contentsOf: buf)
        return out
    }

    private func advance(_ c: UInt8?) {
        if let c {
            // Add to lookahead buffer.
            z.textBuf[s] = c
            if s < F - 1 {
                z.textBuf[s + N] = c
            }
            len += 1
        }

        // Process one byte from lookahead buffer.
        z.insertNode(r)
        lastMatchLength -= 1
        if lastMatchLength == 0 {
            encode()
        }
        z.deleteNode(s)
        s = (s + 1) & (N - 1)
        r = (r + 1) & (N - 1)
        len -= 1
    }

    private func encode() {
        if len == 0 {
            return
        }

        // Encode from lookahead buffer.
        if z.matchLength > len {
            z.matchLength = len
        }
        if z.matchLength <= Threshold {
            z.matchLength = 1
            encodeChar(Int(z.textBuf[r]))
        } else {
            encodeChar(255 - Threshold + z.matchLength)
            encodePosition(z.matchPosition)
        }

        lastMatchLength = z.matchLength
    }

    private func encodeEnd() {
        if putlen == 0 {
            return
        }
        buf.append(UInt8((putbuf >> 8) & 0xff))
    }

    private func encodeChar(_ c: Int) {
        // Travel from leaf to root.
        var i: UInt = 0
        var j = 0
        var k = z.prnt[c + T]
        while true {
            i >>= 1
            j += 1

            // If node's address is odd-numbered, choose bigger brother node.
            if k & 1 != 0 {
                i += 0x8000
            }

            k = z.prnt[k]
            if k == R {
                break
            }
        }
        putCode(j, i)
        z.update(c)
    }

    private func encodePosition(_ c: Int) {
        // Output upper 6 bits by table lookup.
        let i = c >> 6
        putCode(Int(pLen[i]), UInt(pCode[i]) << 8)

        // Output lower 6 bits verbatim.
        putCode(6, UInt(c & 0x3f) << 10)
    }

    // Output l bits of code c (left-aligned at bit 15).
    private func putCode(_ l: Int, _ c: UInt) {
        putbuf |= c >> UInt(putlen)
        putlen += l

        if putlen < 8 {
            return
        }

        buf.append(UInt8((putbuf >> 8) & 0xff))
        putlen -= 8

        if putlen >= 8 {
            buf.append(UInt8(putbuf & 0xff))
            putlen -= 8
            putbuf = c << UInt(l - putlen)
        } else {
            putbuf <<= 8
        }
    }
}

// MARK: - Huffman position tables
// Table for encoding and decoding the upper 6 bits of position.

// For encoding.
private let pCode: [UInt8] = [
    0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68,
    0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
    0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC,
    0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
    0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE,
    0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
    0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
]
private let pLen: [UInt8] = [
    0x03, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
]

// For decoding.
private let dCode: [UInt8] = [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
    0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A,
    0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B,
    0x0C, 0x0C, 0x0C, 0x0C, 0x0D, 0x0D, 0x0D, 0x0D,
    0x0E, 0x0E, 0x0E, 0x0E, 0x0F, 0x0F, 0x0F, 0x0F,
    0x10, 0x10, 0x10, 0x10, 0x11, 0x11, 0x11, 0x11,
    0x12, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x13,
    0x14, 0x14, 0x14, 0x14, 0x15, 0x15, 0x15, 0x15,
    0x16, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x17,
    0x18, 0x18, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B,
    0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F,
    0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23,
    0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27,
    0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B,
    0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x2F,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
]
private let dLen: [UInt8] = [
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
]
