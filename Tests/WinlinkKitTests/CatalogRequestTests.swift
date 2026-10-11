import Testing
@testable import WinlinkKit

struct CatalogRequestTests {

    @Test func winlinkInquiryUsesRequestProtocol() {
        let draft = CatalogRequest.winlinkInquiry(items: ["WL2K_HELP", "USWXRAD.GIF"])
        #expect(draft.to == ["INQUIRY"])
        #expect(draft.subject == "REQUEST")
        #expect(draft.body == "WL2K_HELP\nUSWXRAD.GIF")
        #expect(draft.attachments.isEmpty)
    }

    @Test func saildocsFetchBuildsSendLines() {
        let draft = CatalogRequest.saildocsFetch(urls: [
            "https://example.com/a.html",
            "https://example.com/b.txt",
        ])
        #expect(draft.to == ["query@saildocs.com"])
        #expect(!draft.subject.isEmpty)  // B2F verlangt ein Subject
        #expect(draft.body == "send https://example.com/a.html\nsend https://example.com/b.txt")
    }

    @Test func saildocsGRIBWrapsSpecInSend() {
        let draft = CatalogRequest.saildocsGRIB("GFS:50N,42N,5W,20E|0.5,0.5|0,24|PRMSL,WIND")
        #expect(draft.to == ["query@saildocs.com"])
        #expect(draft.body == "send GFS:50N,42N,5W,20E|0.5,0.5|0,24|PRMSL,WIND")
    }
}

struct GRIBSpecTests {

    @Test func specFormatsAreaGridTimesAndParameters() throws {
        let spec = CatalogRequest.GRIBSpec(
            north: 50, south: 42, west: -5, east: 20,
            resolution: 0.5, hours: [48, 0, 24], parameters: ["prmsl", "WIND"])
        try spec.validate()
        #expect(spec.spec == "GFS:50N,42N,5W,20E|0.5,0.5|0,24,48|PRMSL,WIND")
        #expect(CatalogRequest.saildocsGRIB(spec).body == "send " + spec.spec)
    }

    @Test func aroundBuildsBoxWithDecimals() {
        let spec = CatalogRequest.GRIBSpec.around(latitude: 47.5625, longitude: 9.2917, spanDegrees: 4)
        #expect(spec.spec.hasPrefix("GFS:51.56N,43.56N,5.29E,13.29E|"))
        let polar = CatalogRequest.GRIBSpec.around(latitude: 88, longitude: 178, spanDegrees: 4)
        #expect(polar.north == 90)
        #expect(polar.east == 180)
    }

    @Test func southernAndWesternHemispheres() {
        let spec = CatalogRequest.GRIBSpec(
            north: -30, south: -40, west: -75, east: -60, resolution: 1,
            hours: [0], parameters: ["WIND"])
        #expect(spec.spec == "GFS:30S,40S,75W,60W|1,1|0|WIND")
    }

    @Test func validationRejectsBadInput() {
        func check(_ spec: CatalogRequest.GRIBSpec) -> Bool {
            (try? spec.validate()) == nil
        }
        #expect(check(CatalogRequest.GRIBSpec(north: 42, south: 50, west: 5, east: 20)))
        #expect(check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 20, east: 5)))
        #expect(check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 5, east: 20, resolution: 0)))
        #expect(check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 5, east: 20, hours: [])))
        #expect(check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 5, east: 20, parameters: [""])))
        #expect(!check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 5, east: 20)))
        // Unendlich oder absurd gross darf weder durch die Prüfung noch
        // beim Formatieren den Prozess beenden.
        #expect(check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 5, east: 20, resolution: .infinity)))
        #expect(check(CatalogRequest.GRIBSpec(north: 50, south: 42, west: 5, east: 20, resolution: 1e20)))
        #expect(check(CatalogRequest.GRIBSpec(north: .nan, south: 42, west: 5, east: 20)))
        #expect(CatalogRequest.GRIBSpec.number(1e20) == "100000000000000000000")
        #expect(CatalogRequest.GRIBSpec.number(.infinity) == "inf")
    }
}
