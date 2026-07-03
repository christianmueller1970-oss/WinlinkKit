import Foundation
import Testing
@testable import WinlinkKit

/// Ported from wl2k-go/fbb/message_test.go, plus the golden-file
/// byte-identity test required by the project plan.
struct B2MessageTests {
    // MARK: Golden file

    /// LPE5NXDVLVSQ.b2f: decompress → parse → serialize → byte-identical.
    @Test func goldenMessageRoundtripsByteIdentical() throws {
        let compressed = try LZHUFTests.fixture("LPE5NXDVLVSQ.b2f.lzh")
        let raw = try LZHUF.decode(compressed)
        #expect(raw == (try LZHUFTests.fixture("LPE5NXDVLVSQ.b2f")))

        let message = try B2Message(parsing: raw)
        #expect(message.mid == "LPE5NXDVLVSQ")
        #expect(message.subject == "73 fra Brekke")
        #expect(message.from == Address(addr: "LA5NTA"))
        #expect(message.to == [Address(addr: "LA4TTA")])
        #expect(message.type == .private)
        #expect(message.charset == "ISO-8859-1")
        #expect(message.bodySize == 104)
        #expect(message.files.count == 1)
        #expect(message.files[0].name == "1469042410710.jpg")
        #expect(message.files[0].size == 31028)
        #expect(message.bodyText.contains("prøver meg på å sende et stemningsbilde"))

        #expect(try message.bytes() == raw)
    }

    // MARK: Wire format

    @Test func readsMessageWithWhitespaceBeforeHeader() throws {
        var m1 = B2Message(mycall: "LA5NTA")
        m1.addTo("N0CALL")
        m1.setSubject("Hi")
        m1.setBody("Hello world")

        var data = Data("\r\n\r\n\t ".utf8)
        data.append(try m1.bytes())

        let m2 = try B2Message(parsing: data)
        #expect(m1.header == m2.header)
    }

    @Test func emptyMessageThrows() {
        #expect(throws: WinlinkError.self) {
            _ = try B2Message(parsing: Data())
        }
        #expect(throws: WinlinkError.self) {
            _ = try B2Message(parsing: Data("\r\n\r\nfoobar".utf8))
        }
    }

    @Test func emptyAttachmentRoundtrips() throws {
        var msg = B2Message(mycall: "N0CALL")
        msg.addTo("LA5NTA")
        msg.setSubject("Test")
        msg.setBody("Hello")
        msg.addFile(B2File(name: "foo.txt", data: Data()))

        let wire = try msg.bytes()
        #expect(String(decoding: wire, as: UTF8.self).contains("File: 0 foo.txt"))

        let decoded = try B2Message(parsing: wire)
        #expect(decoded.files.count == 1)
        #expect(decoded.files[0].size == 0)
        #expect(decoded.files[0].name == "foo.txt")
    }

    // MARK: Dates

    @Test(arguments: [
        "2016/12/30 01:00", // The correct format according to winlink.org/B2F.
        "2016.12.30 01:00", // RMS Relay store-and-forward layout.
        "2016-12-30 01:00", // Radio Only via RMS Relay-3.0.30.0.
        "20161230010000",   // BPQ Mail format.
        "Fri, 30 Dec 2016 01:00:00 -0000", // RFC 5322, Appendix A.1.1.
        "Fri, 30 Dec 2016 01:00:00 GMT",   // RFC 5322, Appendix A.6.2 (obsolete).
    ])
    func parsesDateLayouts(string: String) throws {
        var components = DateComponents()
        components.year = 2016; components.month = 12; components.day = 30
        components.hour = 1; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: components)!

        #expect(try B2Date.parse(string) == expected)
    }

    @Test func emptyDateParsesToNil() throws {
        #expect(try B2Date.parse("") == nil)
    }

    @Test func garbageDateThrows() {
        #expect(throws: WinlinkError.self) { try B2Date.parse("not a date") }
    }

    // MARK: Addresses

    @Test(arguments: [
        ("LA5NTA", Address(addr: "LA5NTA")),
        ("la5nta", Address(addr: "LA5NTA")),
        ("LA5NTA@winlink.org", Address(addr: "LA5NTA")),
        ("LA5NTA@WINLINK.org", Address(addr: "LA5NTA")),
        ("la5nta@WINLINK.org", Address(addr: "LA5NTA")),
        ("foo@bar.baz", Address(proto: "SMTP", addr: "foo@bar.baz")),
    ])
    func addressFromString(input: String, expected: Address) {
        #expect(Address(string: input) == expected)
    }

    // MARK: Non-ASCII headers (RFC 2047)

    @Test func encodesNonASCIIFileNames() throws {
        var msg = B2Message(mycall: "NOCALL")
        msg.addFile(B2File(name: "æøå.txt", data: Data()))

        let value = msg.header.get("File")
        #expect(value.allSatisfy { $0.isASCII && !$0.isNewline })
        #expect(value.contains("=?ISO-8859-1?q?"))
    }

    @Test func decodesNonASCIIFileNames() throws {
        // File header value in three wire encodings seen in the wild:
        // Q-encoded (spec-conforming), raw UTF-8 and raw Latin-1.
        let samples: [[UInt8]] = [
            Array("0 =?ISO-8859-1?q?=E6=F8=E5.txt?=".utf8),
            Array("0 æøå.txt".utf8),                                // UTF-8
            [0x30, 0x20, 0xE6, 0xF8, 0xE5] + Array(".txt".utf8),    // Latin-1
        ]

        for (i, fileHeader) in samples.enumerated() {
            var wire = Array("Mid: ABCDEFGHIJKL\r\nBody: 1\r\nDate: 2016/12/30 01:00\r\nFrom: N0CALL\r\nTo: N0CALL\r\n".utf8)
            wire += Array("File: ".utf8) + fileHeader + [0x0D, 0x0A]
            wire += [0x0D, 0x0A]              // end of headers
            wire += Array("x".utf8) + [0x0D, 0x0A] // body (1 byte)
            wire += [0x0D, 0x0A]              // empty attachment + terminator

            let decoded = try B2Message(parsing: Data(wire))
            #expect(decoded.files[0].name == "æøå.txt", "Sample \(i) failed")
        }
    }

    @Test func subjectRoundtripsUmlauts() {
        var msg = B2Message(mycall: "HB9HJI")
        msg.setSubject("Grüsse aus Amriswil äöüß")
        let encoded = msg.header.get("Subject")
        #expect(encoded.hasPrefix("=?ISO-8859-1?q?"))
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(msg.subject == "Grüsse aus Amriswil äöüß")
    }

    // MARK: Body charset (we are Swiss: ü/ö/ä required, ß tested anyway)

    @Test func bodyEncodesLatin1Umlauts() throws {
        var msg = B2Message(mycall: "HB9HJI")
        msg.setBody("Grüezi wohl!\nDie süsse Öhi-Prüfung: ä ö ü ß\n")

        // ISO-8859-1 bytes on the wire
        #expect(msg.body.contains(0xFC)) // ü
        #expect(msg.body.contains(0xF6)) // ö
        #expect(msg.body.contains(0xE4)) // ä
        #expect(msg.body.contains(0xDF)) // ß
        // CRLF enforced
        #expect(msg.bodyText == "Grüezi wohl!\r\nDie süsse Öhi-Prüfung: ä ö ü ß\r\n")
        #expect(msg.bodySize == msg.body.count)
    }

    @Test func longBodyLinesAreWrapped() {
        let line = String(repeating: "x", count: 2000)
        let bytes = B2Message.bodyBytes(from: line)
        let text = String(decoding: bytes, as: UTF8.self)
        for l in text.split(separator: "\r\n") {
            #expect(l.count <= 998)
        }
        #expect(text.replacingOccurrences(of: "\r\n", with: "").count == 2000)
    }

    // MARK: Validation

    @Test func validateCatchesMissingFields() throws {
        var msg = B2Message(mycall: "HB9HJI")
        #expect(throws: WinlinkError.validation(field: "To/Cc", reason: "No recipient")) {
            try msg.validate()
        }
        msg.addTo("LA5NTA")
        #expect(throws: WinlinkError.validation(field: "Body", reason: "Empty body")) {
            try msg.validate()
        }
        msg.setBody("Hello")
        #expect(throws: WinlinkError.validation(field: "Subject", reason: "Empty subject")) {
            try msg.validate()
        }
        msg.setSubject("Hi")
        try msg.validate() // now valid
    }

    @Test func newMessageSetsRequiredHeaders() {
        let msg = B2Message(mycall: "HB9HJI")
        #expect(msg.mid.count == 12)
        #expect(msg.type == .private)
        #expect(msg.mbo == "HB9HJI")
        #expect(msg.from == Address(addr: "HB9HJI"))
        #expect(msg.date != nil)
    }
}
