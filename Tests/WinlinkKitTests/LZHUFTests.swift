import Foundation
import Testing
@testable import WinlinkKit

/// Golden-file and sample tests, ported from wl2k-go/lzhuf/lzhuf_test.go.
struct LZHUFTests {
    static let goldenFiles = [
        "e.txt", "pi.txt", "gettysburg.txt",
        "Mark.Twain-Tom.Sawyer.txt", "LPE5NXDVLVSQ.b2f",
    ]

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    // MARK: Golden files

    @Test(arguments: goldenFiles)
    func decodeMatchesGoldenFile(name: String) throws {
        let plain = try Self.fixture(name)
        let compressed = try Self.fixture(name + ".lzh")
        #expect(try LZHUF.decode(compressed) == plain)
    }

    @Test(arguments: goldenFiles)
    func encodeMatchesGoldenFile(name: String) throws {
        let plain = try Self.fixture(name)
        let compressed = try Self.fixture(name + ".lzh")
        let encoded = LZHUF.encode(plain)

        #expect(encoded[0..<2] == compressed[0..<2], "checksum mismatch")
        #expect(encoded[2..<6] == compressed[2..<6], "length header mismatch")
        #expect(encoded == compressed)
    }

    @Test(arguments: goldenFiles)
    func roundtrip(name: String) throws {
        let plain = try Self.fixture(name)
        #expect(try LZHUF.decode(LZHUF.encode(plain)) == plain)
    }

    // MARK: Samples (from lzhuf_test.go; the two long ones are covered
    // by the golden files above and were not ported)

    static let samples: [(plain: [UInt8], compressed: [UInt8])] = [
        (Array("\n".utf8),
         [0xe, 0x8f, 0x1, 0x0, 0x0, 0x0, 0xcb, 0x0]),
        (Array("foo".utf8),
         [0xb6, 0x47, 0x3, 0x0, 0x0, 0x0, 0xf9, 0x7e, 0xf1, 0x0]),
        (Array("The quick brown fox jumps over the lazy dog\r\nThe quick brown fox jumps over the lazy dog".utf8),
         [0x76, 0x25, 0x58, 0x0, 0x0, 0x0, 0xf0, 0x7d, 0x3e, 0x3a, 0xcf, 0xe8, 0xf, 0xd7,
          0xdf, 0xf7, 0xc2, 0xf7, 0x7f, 0xbf, 0x60, 0x7f, 0xab, 0x7f, 0x2b, 0xa0, 0x4b, 0x7f,
          0x6c, 0xf, 0xcf, 0xf3, 0xff, 0x55, 0x60, 0x2c, 0x3b, 0xba, 0x80, 0x23, 0x3, 0xdf,
          0x8f, 0x68, 0x30, 0x2d, 0x3f, 0xa, 0xff, 0x3c, 0xce, 0x5b, 0xf2, 0x2c]),
        (Array("bar".utf8),
         [0xc7, 0xef, 0x03, 0x00, 0x00, 0x00, 0xf7, 0x7b, 0x7f, 0xc0]),
    ]

    @Test(arguments: samples.indices)
    func decodeSample(index: Int) throws {
        let sample = Self.samples[index]
        let plain = try LZHUF.decode(Data(sample.compressed))
        #expect(plain == Data(sample.plain))
    }

    @Test(arguments: samples.indices)
    func encodeSample(index: Int) throws {
        let sample = Self.samples[index]
        let compressed = LZHUF.encode(Data(sample.plain))
        #expect(compressed == Data(sample.compressed))
    }

    @Test func emptyInputRoundtrips() throws {
        let encoded = LZHUF.encode(Data())
        #expect(try LZHUF.decode(encoded).isEmpty)
    }

    // MARK: Error cases

    @Test func rejectsInvalidChecksum() throws {
        var data = Self.samples[0].compressed
        data[0] = 0x1 // Invalid checksum
        #expect(throws: WinlinkError.invalidChecksum) {
            _ = try LZHUF.decode(Data(data))
        }
    }

    @Test func rejectsTruncatedStream() throws {
        // Sample 2 cut short: header promises more data than the stream holds.
        // The up-front CRC catches the truncation before decoding starts.
        let truncated = Data(Self.samples[2].compressed[..<10])
        #expect(throws: WinlinkError.self) {
            _ = try LZHUF.decode(truncated)
        }
        // Same, but without the CRC header (non-B2): decoder must hit
        // the unexpected end of the bit stream.
        #expect(throws: WinlinkError.self) {
            _ = try LZHUF.decode(truncated.dropFirst(2), b2: false)
        }
    }

    @Test func rejectsTooShortHeaders() {
        #expect(throws: WinlinkError.self) { _ = try LZHUF.decode(Data([0x0])) }
        #expect(throws: WinlinkError.self) { _ = try LZHUF.decode(Data([0x0]), b2: false) }
        #expect(throws: WinlinkError.self) { _ = try LZHUF.decode(Data()) }
    }

    @Test func nonB2ModeOmitsChecksum() throws {
        // The same compressed image without its 2-byte CRC header
        // must decode in non-B2 mode.
        let sample = Self.samples[2]
        let plain = try LZHUF.decode(Data(sample.compressed[2...]), b2: false)
        #expect(plain == Data(sample.plain))
        #expect(LZHUF.encode(Data(sample.plain), b2: false) == Data(sample.compressed[2...]))
    }
}
