// Locator maths against known Swiss positions.
import Foundation
import Testing

@testable import WinlinkKit

@Suite struct MaidenheadTests {
    /// HB9HJI, Amriswil TG — the reference position for «nearby».
    @Test func homeLocatorResolvesToAmriswil() throws {
        let home = try Maidenhead(locator: "JN47PN")

        #expect(abs(home.latitude - 47.5625) < 0.001)
        #expect(abs(home.longitude - 9.29167) < 0.001)
    }

    /// The centre of the cell, not its south-west corner — otherwise
    /// every distance is biased.
    @Test func coarserLocatorsCentreOnTheirCell() throws {
        let square = try Maidenhead(locator: "JN47")

        #expect(abs(square.latitude - 47.5) < 0.0001)
        #expect(abs(square.longitude - 9.0) < 0.0001)
    }

    @Test func extendedSquareRefinesTheSubSquare() throws {
        let six = try Maidenhead(locator: "JN47PN")
        let eight = try Maidenhead(locator: "JN47PN55")

        // The 55 cell sits in the middle of the sub-square, so both
        // stay within one sub-square of each other (2.5' of latitude).
        #expect(six.distanceKm(to: eight) < 1.0)
        #expect(eight.locator == "JN47pn55")
    }

    /// JN47PN → JN36PV: HB9HJI to HB9AK, the gateway of the July RF test.
    @Test func distanceAndBearingToHB9AK() throws {
        let home = try Maidenhead(locator: "JN47PN")
        let hb9ak = try Maidenhead(locator: "JN36PV")

        #expect(abs(home.distanceKm(to: hb9ak) - 168) < 3)
        #expect(abs(home.bearingDegrees(to: hb9ak) - 246) < 3)
    }

    /// JN47PN → JN36HN: HB9MM, the second starter gateway.
    @Test func distanceToHB9MM() throws {
        let home = try Maidenhead(locator: "JN47PN")
        let hb9mm = try Maidenhead(locator: "JN36HN")

        #expect(abs(home.distanceKm(to: hb9mm) - 231) < 4)
    }

    @Test func distanceToSelfIsZero() throws {
        let home = try Maidenhead(locator: "JN47PN")

        #expect(home.distanceKm(to: home) == 0)
    }

    /// Distance is symmetric, the reverse bearing is the back bearing.
    @Test func reverseBearingIsTheBackBearing() throws {
        let home = try Maidenhead(locator: "JN47PN")
        let hb9ak = try Maidenhead(locator: "JN36PV")

        #expect(abs(home.distanceKm(to: hb9ak) - hb9ak.distanceKm(to: home)) < 0.001)

        let forward = home.bearingDegrees(to: hb9ak)
        let back = hb9ak.bearingDegrees(to: home)
        let difference = abs(forward - back)
        // Not exactly 180° on a sphere over long paths, but close here.
        #expect(abs(difference - 180) < 2)
    }

    @Test func bearingIsAlwaysInTheCompassRange() throws {
        let home = try Maidenhead(locator: "JN47PN")
        for locator in ["JN36PV", "JO62QM", "IN80DQ", "JN47PO", "FN31PR", "PM95UQ"] {
            let bearing = try home.bearingDegrees(to: Maidenhead(locator: locator))
            #expect(bearing >= 0 && bearing < 360)
        }
    }

    /// Rigs and web services send every casing; all of them must parse.
    @Test func casingDoesNotMatter() throws {
        let variants = ["JN47PN", "jn47pn", "JN47pn", "Jn47Pn", " JN47PN "]
        let expected = try Maidenhead(locator: "JN47PN")

        for variant in variants {
            let parsed = try Maidenhead(locator: variant)
            #expect(parsed == expected)
            #expect(parsed.locator == "JN47pn")
        }
    }

    @Test(arguments: [
        "", "JN", "JN4", "JN47P", "JN47PN1", "JN47PN123",
        "SN47PN",  // field beyond R
        "JN47YN",  // sub-square beyond X
        "J147PN",  // digit in the field
        "JNXYPN",  // letters in the square
        "47PNJN", "HB9HJI", "JN47-PN",
    ])
    func malformedLocatorsAreRejected(_ locator: String) {
        #expect(!Maidenhead.isValid(locator))
        #expect(throws: WinlinkServiceError.invalidGridSquare(locator)) {
            try Maidenhead(locator: locator)
        }
    }

    @Test(arguments: ["JN47", "JN47PN", "JN47PN55", "AA00", "RR99XX99", "jn47pn"])
    func wellFormedLocatorsAreAccepted(_ locator: String) throws {
        #expect(Maidenhead.isValid(locator))
        let parsed = try Maidenhead(locator: locator)
        #expect(parsed.latitude >= -90 && parsed.latitude <= 90)
        #expect(parsed.longitude >= -180 && parsed.longitude <= 180)
    }
}
