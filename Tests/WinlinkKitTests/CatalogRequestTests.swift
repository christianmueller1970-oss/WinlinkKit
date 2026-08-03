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
