import Testing
@testable import WinlinkKit

struct ParserCompatibilityTests {
    @Test func preservesSIDSearchAndGreedyLastHyphen() throws {
        let cases: [(String, String)] = [
            ("[WL2K-2.8.4.8-B2FWIHJM$]", "B2FWIHJM$"),
            ("[Win-Link-Kit-0.8.0-b2fhm$]", "B2FHM$"),
            ("prefix [Client-1.0-B2F$] suffix", "B2F$"),
            ("[First-1-B2$] [Second-2-FH$]", "FH$"),
            ("[Client-1-B2$]\ntrailing text", "B2$"),
            ("[Clïent-1-b2$]", "B2$")
        ]
        for (line, expected) in cases {
            #expect(try SID(parsing: line).features == expected)
        }
    }

    @Test func preservesEmptySIDFeatureCapture() throws {
        // This is accepted by the existing parser; tightening validation is separate.
        for line in ["[Client-1-]", "[-]", "[Client--]"] {
            #expect(try SID(parsing: line).features.isEmpty)
        }
    }

    @Test func rejectsSIDWithoutAMatchingBracketedFeatureGroup() {
        for line in ["", "WL2K-1-B2$", "[nohyphen]", "[Client-1-B2$", "Client-1-B2$]", "[Client-\nB2$]"] {
            #expect(throws: WinlinkError.malformedInput("Bad SID line: \(line)")) {
                _ = try SID(parsing: line)
            }
        }
    }

    @Test func decodesBothEncodedWordFormsAndCaseVariants() {
        let cases: [(String, String)] = [
            ("=?UTF-8?Q?Hello_world?=", "Hello world"),
            ("=?utf-8?q?caf=C3=A9?=", "café"),
            ("=?ISO-8859-1?Q?caf=E9?=", "café"),
            ("=?UTF-8?B?4pyT?=", "✓"),
            ("=?utf-8?b?8J+agA==?=", "🚀"),
            ("subject: =?UTF-8?Q?Hello_=E2=9C=93?=.", "subject: Hello ✓.")
        ]
        for (header, expected) in cases {
            #expect(RFC2047.decodeHeader(header) == expected)
        }
    }

    @Test func preservesAdjacentEncodedWordWhitespaceRules() {
        let cases: [(String, String)] = [
            ("=?UTF-8?Q?A?= \t  =?UTF-8?Q?B?=", "AB"),
            ("=?UTF-8?Q?A?==?UTF-8?Q?B?=", "AB"),
            ("=?UTF-8?Q?A?=\r\n =?UTF-8?Q?B?=", "A\r\n B"),
            ("=?UTF-8?Q?A?= plain =?UTF-8?Q?B?=", "A plain B")
        ]
        for (header, expected) in cases {
            #expect(RFC2047.decodeHeader(header) == expected)
        }
    }

    @Test func preservesUnicodeBeforeBetweenAndAfterEncodedWords() {
        let cases: [(String, String)] = [
            ("🚀 =?UTF-8?Q?A?= 🧭", "🚀 A 🧭"),
            ("e\u{301} =?UTF-8?Q?A?= 中", "e\u{301} A 中"),
            ("🚀 =?UTF-8?Q?A?= e\u{301} =?UTF-8?Q?B?= 🧭", "🚀 A e\u{301} B 🧭"),
            ("=?UTF-8?B?8J+agA==?= \t =?UTF-8?B?4pyT?=", "🚀✓")
        ]
        for (header, expected) in cases {
            #expect(RFC2047.decodeHeader(header) == expected)
        }
    }

    @Test func preservesMalformedWordsAndPlainHeaderFallbacks() {
        let cases: [(String, String)] = [
            ("unchanged ASCII", "unchanged ASCII"),
            ("café", "café"),
            ("cafÃ©", "café"),
            ("broken =? marker", "broken =? marker"),
            ("=?UTF-8?X?abc?=", "=?UTF-8?X?abc?="),
            ("=??Q?abc?=", "=??Q?abc?="),
            ("=?UTF-8?B?%%%?=", "%%%"),
            ("=?UTF-8?Q?=GG?=", "=GG")
        ]
        for (header, expected) in cases {
            #expect(RFC2047.decodeHeader(header) == expected)
        }
    }
    @Test func preservesSIDGraphemeBoundaries() throws {
        for mark in ["\u{301}", "\u{200D}", "\u{FE0F}"] {
            for line in ["[\(mark)Client-1-B2F$]", "[Client-1-B2F$]\(mark)"] {
                #expect(throws: WinlinkError.malformedInput("Bad SID line: \(line)")) {
                    _ = try SID(parsing: line)
                }
            }
            #expect(try SID(parsing: "[Client-1-\(mark)B2F$]").features == "1-\(mark)B2F$")
        }
    }

    @Test func preservesEncodedWordGraphemeBoundaries() {
        for mark in ["\u{301}", "\u{200D}", "\u{FE0F}"] {
            for header in ["=?UTF-8?Q?\(mark)A?=", "=?UTF-8?Q?A?=\(mark)"] {
                #expect(RFC2047.decodeHeader(header) == header)
            }
        }
    }

}
