import Testing
@testable import WinlinkKit

struct SIDTests {
    @Test func parsesRemoteSID() throws {
        let sid = try SID(parsing: "[WL2K-2.8.4.8-B2FWIHJM$]")
        #expect(sid.features == "B2FWIHJM$")
        #expect(sid.has("B2"))
        #expect(sid.has("b2")) // case-insensitive like Go's sid.Has
        #expect(sid.has("$"))
        try sid.requireB2F()
    }

    @Test func featuresAreTakenAfterLastHyphen() throws {
        // Name and version contain hyphens themselves; the greedy match
        // must still pick everything after the *last* one.
        let sid = try SID(parsing: "[Win-Link-Kit-0.1.0-B2FHM$]")
        #expect(sid.features == "B2FHM$")
    }

    @Test func rejectsMalformedSID() {
        #expect(throws: WinlinkError.malformedInput("Bad SID line: [nohyphen]")) {
            _ = try SID(parsing: "[nohyphen]")
        }
    }

    @Test func rejectsRemoteWithoutB2F() throws {
        let sid = try SID(parsing: "[OLDBBS-1.0-F$]")
        #expect(throws: WinlinkError.unsupportedRemoteSID("F$")) {
            try sid.requireB2F()
        }
    }

    @Test func detectsSIDLines() {
        #expect(SID.isSIDLine("[WL2K-2.8.4.8-B2FWIHJM$]"))
        #expect(!SID.isSIDLine(";PQ: 23753528"))
        #expect(!SID.isSIDLine("FC EM ABCDEFGHIJKL 100 90 0"))
    }

    @Test func generatesOwnSIDLine() {
        #expect(SID.localLine() == "[WinlinkKit-\(WinlinkKit.version)-B2FHM$]")
        #expect(SID.localFeatures.hasSuffix("$")) // BID code must be last
    }
}
