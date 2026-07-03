import Foundation
import Testing
@testable import WinlinkKit

struct MIDTests {
    @Test func midHasProtocolLength() {
        #expect(generateMID(callsign: "HB9HJI").count == MaxMIDLength)
    }

    @Test func midUsesBase32Alphabet() {
        let mid = generateMID(callsign: "HB9HJI")
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        #expect(mid.allSatisfy { alphabet.contains($0) })
    }

    @Test func midIsDeterministicForFixedInput() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = generateMID(callsign: "HB9HJI", date: date)
        let b = generateMID(callsign: "HB9HJI", date: date)
        #expect(a == b)
    }

    @Test func midDiffersAcrossCallsignsAndTimes() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_000.000_000_5)
        #expect(generateMID(callsign: "HB9HJI", date: date)
            != generateMID(callsign: "LA5NTA", date: date))
        #expect(generateMID(callsign: "HB9HJI", date: date)
            != generateMID(callsign: "HB9HJI", date: later))
    }

    /// RFC 4648 test vectors (Base32 replaces Go's encoding/base32 StdEncoding).
    @Test(arguments: [
        (input: "", expect: ""),
        (input: "f", expect: "MY======"),
        (input: "fo", expect: "MZXQ===="),
        (input: "foo", expect: "MZXW6==="),
        (input: "foob", expect: "MZXW6YQ="),
        (input: "fooba", expect: "MZXW6YTB"),
        (input: "foobar", expect: "MZXW6YTBOI======"),
    ])
    func base32EncodesRFC4648Vectors(input: String, expect: String) {
        #expect(Base32.encode(Array(input.utf8)) == expect)
    }
}
