import Foundation
import Testing
@testable import WinlinkKit

struct PositionReportTests {
    private let fix = Date(timeIntervalSince1970: 1_469_030_400)  // 2016/07/20 16:00 UTC

    @Test func coordinatesFormatAsDegreesAndDecimalMinutes() {
        #expect(PositionReport.degreesMinutes(47.5, latitude: true) == "47-30.0000N")
        #expect(PositionReport.degreesMinutes(9.3, latitude: false) == "009-18.0000E")
        #expect(PositionReport.degreesMinutes(-33.8688, latitude: true) == "33-52.1280S")
        #expect(PositionReport.degreesMinutes(-151.2093, latitude: false) == "151-12.5580W")
        // Go's example from the source comment, 23-42.3N, with four decimals.
        #expect(PositionReport.degreesMinutes(23.705, latitude: true) == "23-42.3000N")
        // Exactly zero carries a space instead of a hemisphere letter.
        #expect(PositionReport.degreesMinutes(0, latitude: true) == "00-00.0000 ")
        #expect(PositionReport.degreesMinutes(0, latitude: false) == "000-00.0000 ")
    }

    @Test func bodyListsOnlyWhatIsSet() {
        let minimal = PositionReport(date: fix)
        #expect(minimal.body == "DATE: 2016/07/20 16:00\r\n")

        let full = PositionReport(
            date: fix, latitude: 47.5, longitude: 9.3, speed: 12.5,
            course: PositionReport.Course(degrees: 45, magnetic: true),
            comment: "Wohnmobil, alles OK")
        #expect(full.body == """
            DATE: 2016/07/20 16:00\r
            LATITUDE: 47-30.0000N\r
            LONGITUDE: 009-18.0000E\r
            SPEED: 12.500000\r
            COURSE: 045M\r
            COMMENT: Wohnmobil, alles OK\r

            """)
    }

    /// Latitude without longitude (or vice versa) writes no coordinates
    /// at all — the CMS would not know what to do with half a fix.
    @Test func halfAFixIsOmitted() {
        let report = PositionReport(date: fix, latitude: 47.5)
        #expect(!report.body.contains("LATITUDE"))
    }

    @Test func commentIsCutAtEightyCharacters() {
        let long = String(repeating: "x", count: 100)
        let report = PositionReport(date: fix, comment: long)
        #expect(report.body.hasSuffix("COMMENT: \(String(repeating: "x", count: 80))\r\n"))
    }

    @Test func courseValidatesRange() {
        #expect(PositionReport.Course(degrees: 360)?.degrees == 0)
        #expect(PositionReport.Course(degrees: 5)?.formatted == "005T")
        #expect(PositionReport.Course(degrees: -1) == nil)
        #expect(PositionReport.Course(degrees: 361) == nil)
    }

    @Test func messageGoesToQTHAsPositionReport() throws {
        let report = PositionReport(date: fix, latitude: 47.5, longitude: 9.3, comment: "QRV")
        let message = report.message(mycall: "hb9hji")
        #expect(message.type == .positionReport)
        #expect(message.subject == "POSITION REPORT")
        #expect(message.to == [Address(addr: "QTH")])
        #expect(message.from == Address(addr: "HB9HJI"))
        #expect(message.bodyText == report.body)
        try message.validate()
        // Survives the wire format round trip.
        let parsed = try B2Message(parsing: try message.bytes())
        #expect(parsed.bodyText == report.body)
        #expect(parsed.type == .positionReport)
    }
}
